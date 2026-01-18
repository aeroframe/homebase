#!/usr/bin/env bash
set -e

APP_ROOT="/opt/homebase"
SRC_DIR="$APP_ROOT/src"
WEB_DIR="/var/www/Homebase"

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

# --------------------------------------------------
# 1. System update
# --------------------------------------------------
echo
echo "[1/11] System update"
sudo apt update
sudo apt -y upgrade

# --------------------------------------------------
# 2. Install build + runtime dependencies
# --------------------------------------------------
echo
echo "[2/11] Install build dependencies"

sudo apt install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm \
  python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

# --------------------------------------------------
# 3. Prepare directories
# --------------------------------------------------
echo
echo "[3/11] Prepare source directories"

sudo mkdir -p "$SRC_DIR"
sudo chown -R "$USER:$USER" "$APP_ROOT"

# --------------------------------------------------
# 4. Build dump1090-fa from source
# --------------------------------------------------
echo
echo "[4/11] Build dump1090-fa from source"

cd "$SRC_DIR"

if [ ! -d dump1090 ]; then
  git clone https://github.com/flightaware/dump1090.git
fi

cd dump1090
git fetch origin
git checkout stable

make clean || true
make -j"$(nproc)"

sudo install -m 0755 dump1090 /usr/local/bin/dump1090-fa
sudo install -m 0755 view1090 /usr/local/bin/view1090-fa

# --------------------------------------------------
# 5. Build dump978-fa from source (RTL-SDR ONLY)
# --------------------------------------------------
echo
echo "[5/11] Build dump978-fa from source (RTL-SDR ONLY, NO SOAPY)"

cd "$SRC_DIR"

if [ ! -d dump978 ]; then
  git clone https://github.com/flightaware/dump978.git
fi

cd dump978
git fetch origin
git checkout stable

echo "Hard-disabling SoapySDR in dump978"

# --- Stub header ---
cat > soapy_source.h <<'EOF'
#pragma once
struct SoapySampleSource {
  static SoapySampleSource* Create(...) { return nullptr; }
};
EOF

# --- Stub implementation ---
cat > soapy_source.cc <<'EOF'
#include "soapy_source.h"
// SoapySDR intentionally disabled
EOF

# --- Remove Soapy objects from Makefile ---
sed -i \
  -e 's/soapy_source.o//g' \
  -e 's/soapy_source.cc//g' \
  Makefile

make clean || true
make -j"$(nproc)" NO_SOAPY=1

sudo install -m 0755 dump978-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
# 6. Install Homebase web app
# --------------------------------------------------
echo
echo "[6/11] Install Homebase web app"

sudo mkdir -p "$WEB_DIR"
sudo rsync -a --delete "$APP_ROOT/homebase-app/" "$WEB_DIR/"

sudo chown -R www-data:www-data "$WEB_DIR"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# --------------------------------------------------
# 7. Configure nginx
# --------------------------------------------------
echo
echo "[7/11] Configure nginx"

NGINX_SITE="/etc/nginx/sites-available/homebase"

if [ ! -f "$NGINX_SITE" ]; then
sudo tee "$NGINX_SITE" > /dev/null <<'EOF'
server {
    listen 80 default_server;
    root /var/www/Homebase;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
}
EOF
fi

sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/homebase
sudo rm -f /etc/nginx/sites-enabled/default

sudo systemctl reload nginx

# --------------------------------------------------
# 8. Enable RTL-SDR access
# --------------------------------------------------
echo
echo "[8/11] Enable RTL-SDR access"

sudo usermod -a -G plugdev "$USER"
sudo tee /etc/udev/rules.d/20-rtlsdr.rules > /dev/null <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

# --------------------------------------------------
# 9. Sanity checks
# --------------------------------------------------
echo
echo "[9/11] Sanity checks"

command -v dump1090-fa >/dev/null && echo "✔ dump1090-fa installed"
command -v dump978-fa  >/dev/null && echo "✔ dump978-fa installed"

# --------------------------------------------------
# 10. Notes
# --------------------------------------------------
echo
echo "[10/11] Notes"
echo "• Reboot recommended to apply RTL-SDR permissions"
echo "• dump1090-fa binary: /usr/local/bin/dump1090-fa"
echo "• dump978-fa  binary: /usr/local/bin/dump978-fa"
echo "• Web UI path: /var/www/Homebase"

# --------------------------------------------------
# 11. Done
# --------------------------------------------------
echo
echo "[11/11] Homebase installation complete."
echo "Reboot the system before first use."