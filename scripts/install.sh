#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo: sudo ./scripts/install.sh"
  exit 1
fi

INSTALL_USER="${SUDO_USER:-pi}"

echo "[1/13] System update"
apt-get update -y
apt-get upgrade -y

echo "[2/13] Add FlightAware APT repository (dump1090 / dump978)"

curl -fsSL https://repo.flightaware.com/adsbexchange/repo.gpg \
  | gpg --dearmor \
  | tee /usr/share/keyrings/flightaware-adsb.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/flightaware-adsb.gpg] https://repo.flightaware.com/adsbexchange bookworm stable" \
  | tee /etc/apt/sources.list.d/flightaware.list

apt-get update -y

echo "[3/13] Install packages"
apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  hostapd dnsmasq rfkill \
  chromium \
  dump1090-fa dump978-fa

echo "[4/13] Disable AP services (Homebase controls them)"
systemctl disable --now hostapd dnsmasq || true

echo "[5/13] Create Homebase directories"
mkdir -p /opt/homebase/{app,data,scripts}
chown -R "${INSTALL_USER}:${INSTALL_USER}" /opt/homebase

echo "[6/13] Python deps"
pip3 install --upgrade pip
pip3 install flask

echo "[7/13] Install systemd units"
install -m 644 systemd/*.service /etc/systemd/system/
systemctl daemon-reload

echo "[8/13] Install hotspot configs"
install -m 600 config/hostapd.conf /etc/hostapd/hostapd.conf
install -m 644 config/dnsmasq-homebase.conf /etc/dnsmasq.d/homebase.conf
install -m 644 config/dhcpcd-homebase.conf /etc/dhcpcd.conf.d/homebase.conf
sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "[9/13] Install nginx site"
rm -f /etc/nginx/sites-enabled/default
install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
nginx -t
systemctl restart nginx

echo "[10/13] Install Homebase web app into /var/www/homebase"
mkdir -p /var/www/homebase
rsync -a --delete homebase-app/ /var/www/homebase/
chown -R www-data:www-data /var/www/homebase
chmod -R 755 /var/www/homebase

echo "[11/13] Enable services"
systemctl enable homebase-api
systemctl enable homebase-boot
systemctl enable dump1090-fa
systemctl enable dump978-fa

echo "[12/13] Unblock Wi-Fi"
rfkill unblock wifi || true

echo "[13/13] Ensure scripts executable"
chmod +x /opt/homebase/app/boot_mode.sh || true
chmod +x /opt/homebase/scripts/*.sh || true

echo
echo "======================================"
echo " Install complete"
echo "======================================"
echo "Reboot now: sudo reboot"