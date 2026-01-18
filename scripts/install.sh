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
step() {
  STEP=$((STEP+1))
  echo
  echo "[$STEP/11] $1"
}

# --------------------------------------------------
step "System update"
apt update
apt -y upgrade || true

# --------------------------------------------------
step "Install build dependencies"
apt install -y \
  git curl ca-certificates rsync gnupg \
  nginx php-fpm python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

# --------------------------------------------------
step "Prepare source directories"
mkdir -p "$SRC_DIR"

# --------------------------------------------------
step "Build dump1090-fa from source"
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
step "Build dump978-fa from source (RTL-SDR ONLY, HARD NO SOAPY)"

if [ ! -d "$D978_DIR" ]; then
  git clone https://github.com/flightaware/dump978.git "$D978_DIR"
fi

cd "$D978_DIR"
git fetch origin
git reset --hard origin/master

# --------------------------------------------------
# HARD PATCH: Replace soapy_source.h entirely
# --------------------------------------------------
echo "Patching dump978 to remove SoapySDR entirely"

cat > soapy_source.h <<'EOF'
#pragma once
/* HARD NO-SOAPY stub
 * This file intentionally removes all SoapySDR usage.
 * dump978 RTL-SDR mode only.
 */

struct soapy_source_t {};

static inline soapy_source_t* soapy_source_create(const char*) {
  return nullptr;
}

static inline void soapy_source_destroy(soapy_source_t*) {}

static inline int soapy_source_start(soapy_source_t*) {
  return -1;
}

static inline int soapy_source_stop(soapy_source_t*) {
  return -1;
}
EOF

# --------------------------------------------------
make clean || true
make -j"$(nproc)" NO_SOAPY=1

install -m 755 dump978-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
step "Blacklist DVB kernel drivers (RTL-SDR)"
cat >/etc/modprobe.d/rtl-sdr-blacklist.conf <<EOF
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

# --------------------------------------------------
step "Reload udev rules"
udevadm control --reload-rules
udevadm trigger

# --------------------------------------------------
step "Verify installed binaries"
ls -lh /usr/local/bin/dump1090-fa /usr/local/bin/dump978-fa

# --------------------------------------------------
step "Done"
echo
echo "✅ Homebase install complete"
echo
echo "Test commands:"
echo "  rtl_test -t"
echo "  dump1090-fa --interactive"
echo "  dump978-fa --ifile /dev/null"
echo