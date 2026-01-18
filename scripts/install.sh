#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Homebase Beta Installer (Aeroframe)
# Target: Raspberry Pi 4 / 64-bit OS
###############################################################################

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "  sudo ./scripts/install.sh"
  exit 1
fi

step() {
  echo
  echo "[$1] $2"
}

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

###############################################################################
# 0. Basic network sanity (non-destructive)
###############################################################################
step "0/11" "Ensure DNS resolution"
if getent hosts github.com >/dev/null 2>&1; then
  echo "DNS OK"
else
  echo "WARNING: DNS lookup failed. Network may not be ready."
fi

###############################################################################
# 1. System update
###############################################################################
step "1/11" "System update"
apt-get update -y
apt-get upgrade -y || true

###############################################################################
# 2. Base + build dependencies
###############################################################################
step "2/11" "Install build dependencies"

apt-get install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

###############################################################################
# 3. Build dump1090 (1090 MHz ADS-B)
###############################################################################
step "3/11" "Build dump1090 from source"

if [[ ! -d /opt/dump1090 ]]; then
  git clone https://github.com/flightaware/dump1090 /opt/dump1090
fi

cd /opt/dump1090
git pull
make clean || true
make -j"$(nproc)"

install -m 755 dump1090 /usr/local/bin/dump1090
install -m 755 view1090 /usr/local/bin/view1090

###############################################################################
# 4. Build dump978 (978 MHz UAT) — RTL-SDR ONLY
###############################################################################
step "4/11" "Build dump978 from source (RTL-SDR only)"

if [[ ! -d /opt/dump978 ]]; then
  git clone https://github.com/flightaware/dump978 /opt/dump978
fi

cd /opt/dump978
git pull

# CRITICAL: remove any previous config that enables SoapySDR
rm -f config.mk
make clean || true

# Force RTL-SDR only build
cat > config.mk <<'EOF'
RTLSDR=yes
SOAPYSDR=no
EOF

make -j"$(nproc)"

install -m 755 dump978-fa /usr/local/bin/dump978

###############################################################################
# 5. Homebase directories
###############################################################################
step "5/11" "Create Homebase directories"

mkdir -p /opt/homebase/{app,data,scripts}
mkdir -p /var/www/Homebase

###############################################################################
# 6. Python deps (Homebase API)
###############################################################################
step "6/11" "Install Python dependencies"

python3 -m pip install --upgrade pip
python3 -m pip install flask

###############################################################################
# 7. Install Homebase web app
###############################################################################
step "7/11" "Deploy Homebase web app"

if [[ -d homebase-app ]]; then
  rsync -a --delete homebase-app/ /var/www/Homebase/
else
  echo "WARNING: homebase-app directory not found in repo"
fi

chown -R www-data:www-data /var/www/Homebase
chmod -R 755 /var/www/Homebase

###############################################################################
# 8. Nginx site
###############################################################################
step "8/11" "Configure nginx"

rm -f /etc/nginx/sites-enabled/default

if [[ -f nginx/homebase.conf ]]; then
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
fi

nginx -t
systemctl restart nginx

###############################################################################
# 9. Disable AP services (Homebase controls them later)
###############################################################################
step "9/11" "Disable hotspot services"

systemctl disable --now hostapd dnsmasq || true

###############################################################################
# 10. Permissions
###############################################################################
step "10/11" "Fix permissions"

chown -R root:root /opt/dump1090 /opt/dump978
chmod -R 755 /opt/dump1090 /opt/dump978

###############################################################################
# 11. Done
###############################################################################
step "11/11" "Install complete"

echo
echo "======================================"
echo " Homebase install complete"
echo "======================================"
echo
echo "Binaries installed:"
echo "  dump1090 -> /usr/local/bin/dump1090"
echo "  dump978  -> /usr/local/bin/dump978"
echo
echo "Test next:"
echo "  dump1090 --interactive"
echo "  dump978 --help"
echo
echo "Reboot recommended:"
echo "  sudo reboot"