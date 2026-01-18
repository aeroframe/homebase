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
# [0/13] Ensure DNS resolution (Pi OS compatible)
# --------------------------------------------------
echo "[0/13] Ensure DNS resolution"

if systemctl list-unit-files | grep -q systemd-resolved; then
  echo "Using systemd-resolved"

  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/homebase.conf <<EOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=9.9.9.9
EOF

  systemctl restart systemd-resolved
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
  echo "Using dhcpcd / resolv.conf fallback"

  cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

  # Prevent DHCP overwrite during setup
  chattr +i /etc/resolv.conf || true
fi

# --------------------------------------------------
# [1/13] System update
# --------------------------------------------------
echo "[1/13] System update"
apt-get update -y
apt-get upgrade -y

# --------------------------------------------------
# [2/13] Install base packages
# --------------------------------------------------
echo "[2/13] Install base packages"
apt-get install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  chromium-browser || true

# --------------------------------------------------
# [3/13] Install dump1090 + dump978 (FlightAware)
# --------------------------------------------------
echo "[3/13] Install dump1090-fa and dump978-fa"

if ! apt-cache show dump1090-fa >/dev/null 2>&1; then
  curl -fsSL https://flightaware.com/adsb/piaware/files/packages/piaware-repository_8.2_all.deb -o /tmp/piaware-repo.deb
  dpkg -i /tmp/piaware-repo.deb
  apt-get update
fi

apt-get install -y dump1090-fa dump978-fa

# --------------------------------------------------
# [4/13] Disable AP services (Homebase controls these)
# --------------------------------------------------
echo "[4/13] Disable AP services"
systemctl disable --now hostapd dnsmasq || true

# --------------------------------------------------
# [5/13] Create Homebase directories
# --------------------------------------------------
echo "[5/13] Create Homebase directories"
mkdir -p /opt/homebase/{scripts,data}
mkdir -p /var/www/Homebase
chown -R pi:pi /opt/homebase || true
chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

# --------------------------------------------------
# [6/13] Install Python dependencies
# --------------------------------------------------
echo "[6/13] Python dependencies"
pip3 install --upgrade pip
pip3 install flask requests

# --------------------------------------------------
# [7/13] Install systemd units
# --------------------------------------------------
echo "[7/13] Install systemd services"
if [[ -d systemd ]]; then
  install -m 644 systemd/*.service /etc/systemd/system/
  systemctl daemon-reload
fi

# --------------------------------------------------
# [8/13] Install hotspot configs
# --------------------------------------------------
echo "[8/13] Install hotspot configs"

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

# --------------------------------------------------
# [9/13] Install nginx site
# --------------------------------------------------
echo "[9/13] Install nginx config"

rm -f /etc/nginx/sites-enabled/default || true

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

# --------------------------------------------------
# [10/13] Deploy Homebase web app
# --------------------------------------------------
echo "[10/13] Deploy Homebase web app"

rsync -a --delete homebase-app/ /var/www/Homebase/

chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

# --------------------------------------------------
# [11/13] Enable services
# --------------------------------------------------
echo "[11/13] Enable services"

systemctl enable dump1090-fa
systemctl enable dump978-fa

if systemctl list-unit-files | grep -q homebase-api; then
  systemctl enable homebase-api
fi

if systemctl list-unit-files | grep -q homebase-boot; then
  systemctl enable homebase-boot
fi

# --------------------------------------------------
# [12/13] Unblock Wi-Fi
# --------------------------------------------------
echo "[12/13] Unblock Wi-Fi"
rfkill unblock wifi || true

# --------------------------------------------------
# [13/13] Finalize
# --------------------------------------------------
echo "[13/13] Final cleanup"

# DNS can be unlocked later after Wi-Fi setup
echo "NOTE: /etc/resolv.conf is locked during setup"

echo
echo "======================================"
echo " Homebase installation complete"
echo "======================================"
echo "Reboot now:"
echo "  sudo reboot"