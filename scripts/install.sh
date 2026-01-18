#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "  sudo ./scripts/install.sh"
  exit 1
fi

# --------------------------------------------------
# [0/11] Ensure DNS resolution (safe re-run)
# --------------------------------------------------
echo "[0/11] Ensure DNS resolution"
chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

# --------------------------------------------------
# [1/11] System update
# --------------------------------------------------
echo "[1/11] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------------------
# [2/11] Install base + build dependencies
# --------------------------------------------------
echo "[2/11] Install build dependencies"
apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev

# --------------------------------------------------
# [3/11] Build & install dump1090 (GitHub)
# --------------------------------------------------
echo "[3/11] Build dump1090 from source"

if [[ ! -d /opt/dump1090 ]]; then
  git clone https://github.com/flightaware/dump1090.git /opt/dump1090
fi

cd /opt/dump1090
make clean || true
make -j$(nproc)

install -m 755 dump1090 /usr/local/bin/dump1090

# --------------------------------------------------
# [4/11] Build & install dump978 (GitHub)
# --------------------------------------------------
echo "[4/11] Build dump978 from source"

if [[ ! -d /opt/dump978 ]]; then
  git clone https://github.com/flightaware/dump978.git /opt/dump978
fi

cd /opt/dump978
make clean || true
make -j$(nproc)

install -m 755 dump978 /usr/local/bin/dump978

# --------------------------------------------------
# [5/11] Install systemd services
# --------------------------------------------------
echo "[5/11] Install ADS-B systemd services"

cat > /etc/systemd/system/dump1090.service <<EOF
[Unit]
Description=dump1090 ADS-B Receiver
After=network.target

[Service]
ExecStart=/usr/local/bin/dump1090 --net --device-index 0
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dump978.service <<EOF
[Unit]
Description=dump978 UAT Receiver
After=network.target

[Service]
ExecStart=/usr/local/bin/dump978 --json-port 30978
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dump1090 dump978

# --------------------------------------------------
# [6/11] Disable AP services (managed later)
# --------------------------------------------------
echo "[6/11] Disable AP services"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------------------
# [7/11] Create Homebase directories
# --------------------------------------------------
echo "[7/11] Create Homebase directories"

mkdir -p /opt/homebase/{scripts,data}
mkdir -p /var/www/Homebase

chown -R root:root /opt/homebase
chmod -R 755 /opt/homebase

chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

# --------------------------------------------------
# [8/11] Python deps
# --------------------------------------------------
echo "[8/11] Python dependencies"
pip3 install --upgrade pip
pip3 install flask requests

# --------------------------------------------------
# [9/11] Nginx config
# --------------------------------------------------
echo "[9/11] Install nginx config"

rm -f /etc/nginx/sites-enabled/default || true

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

# --------------------------------------------------
# [10/11] Deploy Homebase web app
# --------------------------------------------------
echo "[10/11] Deploy Homebase web app"
rsync -a --delete homebase-app/ /var/www/Homebase/

# --------------------------------------------------
# [11/11] Finish
# --------------------------------------------------
echo
echo "======================================"
echo " Homebase installed successfully"
echo "======================================"
echo "Reboot recommended:"
echo "  sudo reboot"