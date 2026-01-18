#!/usr/bin/env bash
set -e

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo "======================================"

###############################################################################
# Helpers
###############################################################################
step() {
  echo
  echo "[$1] $2"
}

###############################################################################
# 0. DNS check (non-destructive)
###############################################################################
step "0/11" "Ensure DNS resolution"
if getent hosts github.com >/dev/null; then
  echo "DNS OK"
else
  echo "WARNING: DNS lookup failed for github.com"
fi

###############################################################################
# 1. System update
###############################################################################
step "1/11" "System update"
apt-get update
apt-get -y upgrade || true

###############################################################################
# 2. Build + runtime dependencies
###############################################################################
step "2/11" "Install build dependencies"

apt-get install -y \
  git \
  curl \
  ca-certificates \
  rsync \
  gnupg \
  nginx \
  php-fpm \
  python3 \
  python3-pip \
  dnsmasq \
  hostapd \
  rfkill \
  build-essential \
  cmake \
  pkg-config \
  librtlsdr-dev \
  libusb-1.0-0-dev \
  libncurses-dev \
  libboost-all-dev

###############################################################################
# 3. Build dump1090 (ADS-B / 1090 MHz)
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
# 4. Build dump978 (UAT / 978 MHz) — RTL-SDR ONLY
###############################################################################
step "4/11" "Build dump978 from source (RTL-SDR only)"

if [[ ! -d /opt/dump978 ]]; then
  git clone https://github.com/flightaware/dump978 /opt/dump978
fi

cd /opt/dump978
git pull
make clean || true

# dump978 REQUIRES config.mk to disable SoapySDR
cat > config.mk <<'EOF'
RTLSDR=yes
SOAPYSDR=no
EOF

make -j"$(nproc)"

install -m 755 dump978-fa /usr/local/bin/dump978

###############################################################################
# 5. RTL-SDR permissions
###############################################################################
step "5/11" "Configure RTL-SDR permissions"

cat > /etc/udev/rules.d/20-rtlsdr.rules <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", MODE="0666"
EOF

udevadm control --reload-rules
udevadm trigger

###############################################################################
# 6. Verify binaries
###############################################################################
step "6/11" "Verify installs"

command -v dump1090 >/dev/null && echo "dump1090 OK"
command -v dump978  >/dev/null && echo "dump978 OK"

###############################################################################
# 7. Done
###############################################################################
step "11/11" "Install complete"

echo
echo "======================================"
echo " Homebase install completed successfully"
echo "======================================"
echo
echo "Next steps:"
echo "  • Plug in RTL-SDR dongle(s)"
echo "  • Test with: sudo dump1090 --interactive"
echo "  • Test with: sudo dump978 --help"
echo