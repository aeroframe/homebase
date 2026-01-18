#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo " Raspberry Pi 4 / 64-bit OS"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "  sudo ./scripts/install.sh"
  exit 1
fi

BASE_DIR="/opt/homebase"
SRC_DIR="$BASE_DIR/src"

# --------------------------------------------------
# [1/10] System update
# --------------------------------------------------
echo "[1/10] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------------------
# [2/10] Dependencies
# --------------------------------------------------
echo "[2/10] Install dependencies"

apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

# --------------------------------------------------
# [3/10] Directories
# --------------------------------------------------
echo "[3/10] Create directories"
mkdir -p "$SRC_DIR"
mkdir -p /var/www/homebase

# --------------------------------------------------
# [4/10] dump1090-fa
# --------------------------------------------------
echo "[4/10] Build dump1090-fa"

cd "$SRC_DIR"

if [[ ! -d dump1090 ]]; then
  git clone https://github.com/flightaware/dump1090.git
fi

cd dump1090
git fetch --tags
git checkout v10.2

make clean
make -j"$(nproc)"

install -m 755 dump1090 /usr/local/bin/dump1090-fa

# --------------------------------------------------
# [5/10] dump978-fa (NO SOAPY)
# --------------------------------------------------
echo "[5/10] Build dump978-fa (RTL-SDR only, NO SoapySDR)"

cd "$SRC_DIR"

if [[ ! -d dump978 ]]; then
  git clone https://github.com/flightaware/dump978.git
fi

cd dump978
git fetch --tags
git checkout v10.2

make clean
make NO_SOAPY=1 -j"$(nproc)"

install -m 755 dump978-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
# [6/10] Web app
# --------------------------------------------------
echo "[6/10] Install Homebase web app"

rsync -a --delete "$BASE_DIR/homebase-app/" /var/www/homebase/
chown -R www-data:www-data /var/www/homebase
chmod -R 755 /var/www/homebase

# --------------------------------------------------
# [7/10] nginx
# --------------------------------------------------
echo "[7/10] Configure nginx"

rm -f /etc/nginx/sites-enabled/default || true
install -m 644 "$BASE_DIR/nginx/homebase.conf" /etc/nginx/sites-available/homebase
ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase

nginx -t
systemctl restart nginx

# --------------------------------------------------
# [8/10] AP services
# --------------------------------------------------
echo "[8/10] Disable hostapd / dnsmasq"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------------------
# [9/10] Wi-Fi
# --------------------------------------------------
echo "[9/10] Ensure Wi-Fi enabled"
rfkill unblock wifi || true

# --------------------------------------------------
# [10/10] Done
# --------------------------------------------------
echo "======================================"
echo " Homebase install COMPLETE"
echo
echo "Test commands:"
echo "  dump1090-fa --net"
echo "  dump978-fa --net"
echo
echo "No SDR attached = expected warnings"
echo "======================================"