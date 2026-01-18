#!/usr/bin/env bash
set -e

echo "======================================"
echo " Homebase Beta Installer (Aeroframe)"
echo " Raspberry Pi 4 / 64-bit OS"
echo "======================================"

SRC_DIR="/opt/homebase/src"
BIN_DIR="/usr/local/bin"

echo "[1/8] System update"
apt update
apt upgrade -y

echo "[2/8] Install base dependencies"
apt install -y \
  git curl ca-certificates rsync \
  nginx php-fpm python3 python3-pip \
  dnsmasq hostapd rfkill \
  build-essential cmake pkg-config \
  librtlsdr-dev libusb-1.0-0-dev \
  libncurses-dev libboost-all-dev

echo "[3/8] Install SoapySDR"
apt install -y \
  soapysdr-tools \
  libsoapysdr-dev \
  soapysdr-module-rtlsdr \
  soapysdr-module-airspy \
  soapysdr-module-hackrf

echo "[4/8] Prepare source directories"
mkdir -p "$SRC_DIR"

echo "[5/8] Build dump1090-fa"
cd "$SRC_DIR"
rm -rf dump1090
git clone https://github.com/flightaware/dump1090.git
cd dump1090
make -j$(nproc)
install -m 755 dump1090 "$BIN_DIR/dump1090-fa"

echo "[6/8] Build dump978-fa"
cd "$SRC_DIR"
rm -rf dump978
git clone https://github.com/flightaware/dump978.git
cd dump978
make -j$(nproc)
install -m 755 dump978-fa "$BIN_DIR/dump978-fa"

echo "[7/8] Verify installs"
dump1090-fa --version || true
dump978-fa --help || true

echo "[8/8] Done"
echo "✔ dump1090-fa installed"
echo "✔ dump978-fa installed"
echo "✔ SoapySDR installed"