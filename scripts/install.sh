#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo: sudo ./scripts/install.sh"
  exit 1
fi

echo "[1/12] System update"
apt-get update -y
apt-get upgrade -y

echo "[2/12] Install packages"
apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  hostapd dnsmasq \
  chromium-browser \
  rfkill \
  dump1090-fa dump978-fa

echo "[3/12] Disable AP services (Homebase controls them)"
systemctl disable --now hostapd dnsmasq || true

echo "[4/12] Create Homebase directories"
mkdir -p /opt/homebase/{app,data,scripts}
chown -R pi:pi /opt/homebase

echo "[5/12] Python deps"
pip3 install --upgrade pip
pip3 install flask

echo "[6/12] Install systemd units"
install -m 644 systemd/*.service /etc/systemd/system/
systemctl daemon-reload

echo "[7/12] Install hotspot configs"
install -m 600 config/hostapd.conf /etc/hostapd/hostapd.conf
install -m 644 config/dnsmasq-homebase.conf /etc/dnsmasq.d/homebase.conf
install -m 644 config/dhcpcd-homebase.conf /etc/dhcpcd.conf.d/homebase.conf
sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "[8/12] Install nginx site"
rm -f /etc/nginx/sites-enabled/default
install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
nginx -t
systemctl restart nginx

echo "[9/12] Install Homebase web app into /var/www/homebase"
mkdir -p /var/www/homebase
rsync -a --delete homebase-app/ /var/www/homebase/
chown -R www-data:www-data /var/www/homebase
chmod -R 755 /var/www/homebase

echo "[10/12] Enable services"
systemctl enable homebase-api
systemctl enable homebase-boot
systemctl enable dump1090-fa
systemctl enable dump978-fa

echo "[11/12] Unblock Wi-Fi"
rfkill unblock wifi || true

echo "[12/12] Ensure scripts executable"
chmod +x /opt/homebase/app/boot_mode.sh || true
chmod +x /opt/homebase/scripts/*.sh || true

echo
echo "======================================"
echo " Install complete"
echo "======================================"
echo "Reboot now: sudo reboot"