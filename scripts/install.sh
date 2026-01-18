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
# [0/13] Ensure DNS works (systemd-resolved)
# --------------------------------------
echo "[0/13] Ensure DNS resolution"

mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/homebase.conf <<EOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=9.9.9.9
EOF

systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# --------------------------------------
# [1/13] System update
# --------------------------------------
echo "[1/13] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------
# [2/13] Base packages
# --------------------------------------
echo "[2/13] Install base packages"
apt-get install -y \
  git curl ca-certificates rsync \
  nginx php-fpm \
  python3 python3-pip \
  hostapd dnsmasq rfkill \
  gnupg

# --------------------------------------
# [3/13] Add FlightAware repo (retry + safe)
# --------------------------------------
echo "[3/13] Add FlightAware APT repository (dump1090 / dump978)"

FA_REPO_OK=false

for i in {1..5}; do
  echo "Attempt $i to reach repo.flightaware.com..."
  if curl -fsSL https://repo.flightaware.com/flightaware.gpg \
    | gpg --dearmor -o /usr/share/keyrings/flightaware.gpg; then
    FA_REPO_OK=true
    break
  fi
  sleep 3
done

if [[ "$FA_REPO_OK" == true ]]; then
  cat > /etc/apt/sources.list.d/flightaware.list <<EOF
deb [signed-by=/usr/share/keyrings/flightaware.gpg] https://repo.flightaware.com/flightaware bookworm main
EOF

  apt-get update -y
  apt-get install -y dump1090-fa dump978-fa
else
  echo "⚠️  FlightAware repo unreachable."
  echo "⚠️  dump1090-fa / dump978-fa NOT installed."
  echo "⚠️  Rerun install.sh after Wi-Fi is configured."
fi

# --------------------------------------
# [4/13] Disable AP services (Homebase controls)
# --------------------------------------
echo "[4/13] Disable hostapd / dnsmasq"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------
# [5/13] Create directories
# --------------------------------------
echo "[5/13] Create Homebase directories"
mkdir -p /opt/homebase/{app,data,scripts}
mkdir -p /var/www/homebase

chown -R aeroframe-admin:aeroframe-admin /opt/homebase || true
chown -R www-data:www-data /var/www/homebase

# --------------------------------------
# [6/13] Python dependencies
# --------------------------------------
echo "[6/13] Install Python dependencies"
pip3 install --upgrade pip
pip3 install flask

# --------------------------------------
# [7/13] Install systemd services
# --------------------------------------
echo "[7/13] Install systemd units"
if compgen -G "systemd/*.service" > /dev/null; then
  install -m 644 systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
fi

# --------------------------------------
# [8/13] Install hotspot configs (optional)
# --------------------------------------
echo "[8/13] Install hotspot configuration"

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
# [9/13] Configure nginx
# --------------------------------------
echo "[9/13] Configure nginx"
rm -f /etc/nginx/sites-enabled/default || true

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

# --------------------------------------
# [10/13] Deploy Homebase web app
# --------------------------------------
echo "[10/13] Deploy Homebase web app"
if [[ -d homebase-app ]]; then
  rsync -a --delete homebase-app/ /var/www/homebase/
  chown -R www-data:www-data /var/www/homebase
  chmod -R 755 /var/www/homebase
fi

# --------------------------------------
# [11/13] Enable services
# --------------------------------------
echo "[11/13] Enable services"

if systemctl list-unit-files | grep -q dump1090-fa; then
  systemctl enable dump1090-fa
fi

if systemctl list-unit-files | grep -q dump978-fa; then
  systemctl enable dump978-fa
fi

if systemctl list-unit-files | grep -q homebase-api; then
  systemctl enable homebase-api
fi

if systemctl list-unit-files | grep -q homebase-boot; then
  systemctl enable homebase-boot
fi

# --------------------------------------
# [12/13] Final permissions
# --------------------------------------
echo "[12/13] Final permissions"
chmod +x /opt/homebase/scripts/*.sh 2>/dev/null || true
chmod +x /opt/homebase/app/*.sh 2>/dev/null || true

# --------------------------------------
# [13/13] Done
# --------------------------------------
echo
echo "======================================"
echo " Homebase install complete"
echo "======================================"
echo "If ADS-B was skipped, re-run after Wi-Fi setup:"
echo "sudo ./scripts/install.sh"
echo
echo "Reboot recommended:"
echo "sudo reboot"