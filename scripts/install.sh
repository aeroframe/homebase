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
# [0/12] Ensure DNS resolution (idempotent & Pi-safe)
# --------------------------------------------------
echo "[0/12] Ensure DNS resolution"

# Always unlock first (safe even if not immutable)
chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

# Lock during install to prevent DHCP overwrite
chattr +i /etc/resolv.conf || true

# --------------------------------------------------
# [1/12] System update
# --------------------------------------------------
echo "[1/12] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------------------
# [2/12] Install base packages
# --------------------------------------------------
echo "[2/12] Install base packages"
apt-get install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill

# --------------------------------------------------
# [3/12] Install FlightAware APT repository
# --------------------------------------------------
echo "[3/12] Install FlightAware repository"

if ! dpkg -l | grep -q piaware-repository; then
  curl -fsSL \
    https://flightaware.com/adsb/piaware/files/packages/piaware-repository_8_all.deb \
    -o /tmp/piaware-repo.deb

  dpkg -i /tmp/piaware-repo.deb
  apt-get update
fi

# --------------------------------------------------
# [4/12] Install dump1090-fa and dump978-fa
# --------------------------------------------------
echo "[4/12] Install dump1090-fa and dump978-fa"
apt-get install -y dump1090-fa dump978-fa

# --------------------------------------------------
# [5/12] Disable AP services (Homebase manages later)
# --------------------------------------------------
echo "[5/12] Disable AP services"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------------------
# [6/12] Create Homebase directories
# --------------------------------------------------
echo "[6/12] Create Homebase directories"

mkdir -p /opt/homebase/{scripts,data}
mkdir -p /var/www/Homebase

chown -R root:root /opt/homebase
chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

# --------------------------------------------------
# [7/12] Python dependencies
# --------------------------------------------------
echo "[7/12] Python dependencies"
pip3 install --upgrade pip
pip3 install flask requests

# --------------------------------------------------
# [8/12] Install systemd services (if present)
# --------------------------------------------------
echo "[8/12] Install systemd units"

if [[ -d systemd ]]; then
  install -m 644 systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
fi

# --------------------------------------------------
# [9/12] Install nginx configuration
# --------------------------------------------------
echo "[9/12] Install nginx config"

rm -f /etc/nginx/sites-enabled/default || true

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

# --------------------------------------------------
# [10/12] Deploy Homebase web app
# --------------------------------------------------
echo "[10/12] Deploy Homebase web app"

rsync -a --delete homebase-app/ /var/www/Homebase/

chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

# --------------------------------------------------
# [11/12] Enable ADS-B services
# --------------------------------------------------
echo "[11/12] Enable ADS-B services"

systemctl enable dump1090-fa
systemctl enable dump978-fa

# --------------------------------------------------
# [12/12] Finish
# --------------------------------------------------
echo "[12/12] Finalize installation"

echo
echo "======================================"
echo " Homebase installation complete"
echo "======================================"
echo "Recommended next step:"
echo "  sudo reboot"