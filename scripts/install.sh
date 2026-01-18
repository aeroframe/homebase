#!/usr/bin/env bash
set -e

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"
echo

BASE_DIR="/opt/homebase"
SRC_DIR="$BASE_DIR/src"
D1090_DIR="$SRC_DIR/dump1090"
D978_DIR="$SRC_DIR/dump978"

STEP=0
next() {
  STEP=$((STEP+1))
  echo
  echo "[$STEP/11] $1"
}

# --------------------------------------------------
next "System update"
apt update
apt -y upgrade || true

# --------------------------------------------------
next "Install build dependencies"
apt install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

# --------------------------------------------------
next "Prepare source directories"
mkdir -p "$SRC_DIR"

# --------------------------------------------------
next "Build dump1090-fa from source"
if [ ! -d "$D1090_DIR" ]; then
  git clone https://github.com/flightaware/dump1090.git "$D1090_DIR"
fi

cd "$D1090_DIR"
git fetch origin
git reset --hard origin/master

make clean || true
make -j"$(nproc)"

install -m 755 dump1090 /usr/local/bin/dump1090-fa
install -m 755 view1090 /usr/local/bin/view1090-fa

# --------------------------------------------------
next "Build dump978-fa from source (NO SOAPY)"

if [ ! -d "$D978_DIR" ]; then
  git clone https://github.com/flightaware/dump978.git "$D978_DIR"
fi

cd "$D978_DIR"
git fetch origin
git reset --hard origin/master

# ---- PATCH soapy_source.h safely ----
PATCH_MARKER="AEROFAME_NO_SOAPY_PATCH"

if ! grep -q "$PATCH_MARKER" soapy_source.h; then
  echo "Applying NO_SOAPY patch to soapy_source.h"

  sed -i '1i\
#ifndef NO_SOAPY\
#include <SoapySDR/Device.hpp>\
#include <SoapySDR/Types.hpp>\
#endif\
/* AEROFAME_NO_SOAPY_PATCH */\
' soapy_source.h
else
  echo "NO_SOAPY patch already applied"
fi

make clean || true
make -j"$(nproc)" NO_SOAPY=1

install -m 755 dump978-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
next "Blacklist DVB kernel drivers (RTL-SDR)"
cat >/etc/modprobe.d/rtl-sdr-blacklist.conf <<EOF
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

# --------------------------------------------------
next "Reload udev rules"
udevadm control --reload-rules
udevadm trigger

# --------------------------------------------------
next "Install completed binaries"
ls -lh /usr/local/bin/dump1090-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
next "Done"
echo
echo "✅ Homebase install complete"
echo
echo "Next steps:"
echo "  • Plug in RTL-SDR"
echo "  • Test dump1090:"
echo "      dump1090-fa --interactive"
echo "  • Test dump978:"
echo "      dump978-fa --ifile /dev/null"
echo