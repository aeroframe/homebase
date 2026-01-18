#!/usr/bin/env bash
set -e

########################################
# Homebase Beta Installer (Aeroframe)
########################################

SRC_DIR="/opt/homebase/src"

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

########################################
# 1. System update
########################################
echo
echo "[1/11] System update"
sudo apt update
sudo apt -y upgrade

########################################
# 2. Install build dependencies
########################################
echo
echo "[2/11] Install build dependencies"
sudo apt install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

########################################
# 3. Prepare source directories
########################################
echo
echo "[3/11] Prepare source directories"
sudo mkdir -p "$SRC_DIR"
sudo chown -R "$USER":"$USER" "$SRC_DIR"

########################################
# 4. Build dump1090-fa (FlightAware)
########################################
echo
echo "[4/11] Build dump1090-fa from source"

cd "$SRC_DIR"

if [ ! -d dump1090 ]; then
  git clone https://github.com/flightaware/dump1090.git
fi

cd dump1090
git fetch --tags

D1090_TAG=$(git tag --sort=-v:refname | head -n1)
echo "Using dump1090 tag: $D1090_TAG"
git checkout "$D1090_TAG"

make clean || true
make -j"$(nproc)"

sudo install -m 0755 dump1090 /usr/local/bin/dump1090-fa
sudo install -m 0755 view1090 /usr/local/bin/view1090-fa

########################################
# 5. Build dump978-fa (RTL-SDR ONLY)
########################################
echo
echo "[5/11] Build dump978-fa from source (RTL-SDR ONLY, NO SOAPY)"

cd "$SRC_DIR"

if [ ! -d dump978 ]; then
  git clone https://github.com/flightaware/dump978.git
fi

cd dump978
git fetch --tags

D978_TAG=$(git tag --sort=-v:refname | head -n1)
echo "Using dump978 tag: $D978_TAG"
git checkout "$D978_TAG"

echo "Hard-disabling SoapySDR"

# Completely stub SoapySDR out
cat > soapy_source.h <<'EOF'
#pragma once
struct SoapySampleSource {
  static SoapySampleSource* Create(...) { return nullptr; }
};
EOF

cat > soapy_source.cc <<'EOF'
#include "soapy_source.h"
EOF

# Remove from build
sed -i \
  -e 's/soapy_source.o//g' \
  -e 's/soapy_source.cc//g' \
  Makefile

make clean || true
make -j"$(nproc)" NO_SOAPY=1

sudo install -m 0755 dump978-fa /usr/local/bin/dump978-fa

########################################
# 6. Final summary
########################################
echo
echo "[6/11] Install complete"
echo
echo "Installed binaries:"
echo "  - /usr/local/bin/dump1090-fa"
echo "  - /usr/local/bin/view1090-fa"
echo "  - /usr/local/bin/dump978-fa"
echo
echo "Next steps:"
echo "  dump1090-fa --net"
echo "  dump978-fa --net"
echo
echo "Systemd services are NOT installed yet (intentional)."
echo "======================================"