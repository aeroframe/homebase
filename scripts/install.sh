#!/usr/bin/env bash
set -e

###############################################################################
# Homebase Beta Installer (Aeroframe)
###############################################################################

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
# 0. DNS sanity check (non-destructive)
###############################################################################
step "0/11" "Ensure DNS resolution"

if getent hosts deb.debian.org >/dev/null 2>&1; then
  echo "DNS OK"
else
  echo "WARNING: DNS lookup failed"
fi

###############################################################################
# 1. System update
###############################################################################
step "1/11" "System update"

apt-get update
apt-get -y upgrade || true

###############################################################################
# 2. Build dependencies
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
# 3. dump1090 (FlightAware) — FROM SOURCE
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
# 4. dump978 (FlightAware) — RTL-SDR ONLY, NO SOAPY
###############################################################################
step "4/11" "Build dump978 from source (RTL-SDR only, NO SOAPY)"

if [[ ! -d /opt/dump978 ]]; then
  git clone https://github.com/flightaware/dump978 /opt/dump978
fi

cd /opt/dump978
git pull
make clean || true

# HARD disable SoapySDR (this is the critical fix)
export CFLAGS="-DNO_SOAPY"
export CXXFLAGS="-DNO_SOAPY"

make -j"$(nproc)"

install -m 755 dump978-fa /usr/local/bin/dump978

###############################################################################
# 5. Permissions sanity
###############################################################################
step "5/11" "Ensure SDR access"

cat >/etc/udev/rules.d/20-rtl-sdr.rules <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0666"
EOF

udevadm control --reload-rules
udevadm trigger

###############################################################################
# 6. Summary
###############################################################################
step "11/11" "Installation complete"

echo
echo "✔ dump1090 installed at: /usr/local/bin/dump1090"
echo "✔ dump978 installed at: /usr/local/bin/dump978"
echo
echo "Test commands:"
echo "  dump1090 --interactive"
echo "  dump978 --help"
echo
echo "NOTE: No systemd services installed yet."