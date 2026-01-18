#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

# Must be run as root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "  sudo ./scripts/install.sh"
  exit 1
fi

###############################################################################
# 0. DNS sanity check (non-destructive)
###############################################################################
echo "[0/11] Ensure DNS resolution"
if ! getent hosts github.com >/dev/null; then
  echo "WARNING: DNS lookup failed. Check network connectivity."
else
  echo "DNS OK"
fi

###############################################################################
# 1. System update
###############################################################################
echo "[1/11] System update"
apt-get update -y
apt-get upgrade -y || true

###############################################################################
# 2. Install build + runtime dependencies
###############################################################################
echo "[2/11] Install build dependencies"

apt-get install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev \
  libboost-all-dev

###############################################################################
# 3. Build dump1090 (1090 MHz ADS-B)
###############################################################################
echo "[3/11] Build dump1090 from source"

if [[ ! -d /opt/dump1090 ]]; then
  git clone https://github.com/flightaware/dump1090 /opt/dump1090
fi

cd /opt/dump1090
git pull
make clean || true
make -j"$(nproc)"
install -m 755 dump1090 /usr/local/bin/dump1090

###############################################################################
# 4. Build dump978 (978 MHz UAT)
###############################################################################
echo "[4/11] Build dump978 from source"

if [[ ! -d /opt/dump978 ]]; then
  git clone https://github.com/flightaware/dump978 /opt/dump978
fi

cd /opt/dump978
git pull
make clean || true
make -j"$(nproc)"
install -m 755 dump978-fa /usr/local/bin/dump978

###############################################################################
# 5. Create Homebase directories
###############################################################################
echo "[5/11] Create Homebase directories"

mkdir -p /opt/homebase/{app,data,scripts,config}
mkdir -p /var/www/Homebase

chown -R root:root /opt/homebase
chown -R www-data:www-data /var/www/Homebase

###############################################################################
# 6. Install Homebase web app
###############################################################################
echo "[6/11] Install Homebase web app"

rsync -a --delete homebase-app/ /var/www/Homebase/
chmod -R 755 /var/www/Homebase

###############################################################################
# 7. Install systemd services
###############################################################################
echo "[7/11] Install systemd units"

if compgen -G "systemd/*.service" > /dev/null; then
  install -m 644 systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
fi

###############################################################################
# 8. Install nginx config
###############################################################################
echo "[8/11] Configure nginx"

rm -f /etc/nginx/sites-enabled/default || true
install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase

nginx -t
systemctl restart nginx

###############################################################################
# 9. Enable services
###############################################################################
echo "[9/11] Enable services"

systemctl enable dump1090 || true
systemctl enable dump978 || true

systemctl enable homebase-api || true
systemctl enable homebase-boot || true

###############################################################################
# 10. Unblock Wi-Fi (needed for AP / setup mode)
###############################################################################
echo "[10/11] Unblock Wi-Fi"
rfkill unblock wifi || true

###############################################################################
# 11. Done
###############################################################################
echo
echo "======================================"
echo " Homebase install complete"
echo "======================================"
echo "Reboot recommended:"
echo "  sudo reboot"