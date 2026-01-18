#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "sudo ./scripts/install.sh"
  exit 1
fi

# --------------------------------------
# [0] Ensure DNS works (critical on fresh Pi OS)
# --------------------------------------
echo "[0/13] Ensure DNS resolution"
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# --------------------------------------
# [1] System update
# --------------------------------------
echo "[1/13] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------
# [2] Base packages
# --------------------------------------
echo "[2/13] Install base packages"
apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  hostapd dnsmasq rfkill \
  gnupg

# --------------------------------------
# [3] Add FlightAware repository (Bookworm fallback)
# --------------------------------------
echo "[3/13] Add FlightAware APT repository (dump1090 / dump978)"

curl -fsSL https://repo.flightaware.com/flightaware.gpg | \
  gpg --dearmor -o /usr/share/keyrings/flightaware.gpg

cat > /etc/apt/sources.list.d/flightaware.list <<EOF
deb [signed-by=/usr/share/keyrings/flightaware.gpg] https://repo.flightaware.com/flightaware bookworm main
EOF

apt-get update -y

# --------------------------------------
# [4] Install ADS-B software
# --------------------------------------
echo "[4/13] Install dump1090-fa and dump978-fa"
apt-get install -y dump1090-fa dump978-fa

# --------------------------------------
# [5] Disable AP services (Homebase controls them)
# --------------------------------------
echo "[5/13] Disable hostapd / dnsmasq (managed by Homebase)"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------
# [6] Create Homebase directories
# --------------------------------------
echo "[6/13] Create Homebase directories"
mkdir -p /opt/homebase/{app,data,scripts}
mkdir -p /var/www/homebase

chown -R aeroframe-admin:aeroframe-admin /opt/homebase || true
chown -R www-data:www-data /var/www/homebase

# --------------------------------------
# [7] Python dependencies
# --------------------------------------
echo "[7/13] Install Python dependencies"
pip3 install --upgrade pip
pip3 install flask

# --------------------------------------
# [8] Install systemd units
# --------------------------------------
echo "[8/13] Install systemd services"
if compgen -G "systemd/*.service" > /dev/null; then
  install -m 644 systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
fi

# --------------------------------------
# [9] Install hotspot configs (optional)
# --------------------------------------
echo "[9/13] Install hotspot configuration"
if [[ -f config/hostapd.conf ]]; then
  install -m 600 config/hostapd.conf /etc/hostapd/hostapd.conf
  sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
fi

if [[ -f config/dnsmasq-homebase.conf ]]; then
  install -m 644 config/dnsmasq-homebase.conf /etc/dnsmasq.d/homebase.conf
fi

if [[ -f config/dhcpcd-homebase.conf ]]; then
  install -m 644 config/dhcpcd-homebase.conf /etc/dhcpcd.conf.d/homebase.conf
fi

# --------------------------------------
# [10] Install nginx site
# --------------------------------------
echo "[10/13] Configure nginx"
rm -f /etc/nginx/sites-enabled/default || true

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

# --------------------------------------
# [11] Deploy Homebase web app
# --------------------------------------
echo "[11/13] Deploy Homebase web app"
if [[ -d homebase-app ]]; then
  rsync -a --delete homebase-app/ /var/www/homebase/
  chown -R www-data:www-data /var/www/homebase
  chmod -R 755 /var/www/homebase
fi

# --------------------------------------
# [12] Enable services
# --------------------------------------
echo "[12/13] Enable services"
systemctl enable dump1090-fa
systemctl enable dump978-fa

if systemctl list-unit-files | grep -q homebase-api; then
  systemctl enable homebase-api
fi

if systemctl list-unit-files | grep -q homebase-boot; then
  systemctl enable homebase-boot
fi

# --------------------------------------
# [13] Final permissions
# --------------------------------------
echo "[13/13] Finalize permissions"
chmod +x /opt/homebase/scripts/*.sh 2>/dev/null || true
chmod +x /opt/homebase/app/*.sh 2>/dev/null || true

echo
echo "======================================"
echo " Homebase install complete"
echo "======================================"
echo "Reboot recommended:"
echo "sudo reboot"