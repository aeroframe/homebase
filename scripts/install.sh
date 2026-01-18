#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Homebase Installer (Aeroframe)
# Raspberry Pi / Debian Trixie / 64-bit
# ----------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
}

detect_php_sock() {
  ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true
}

# ---------------------------
# Identity
# ---------------------------
install_identity() {
  log "Configure hostname + mDNS"
  hostnamectl set-hostname homebase || true
  apt-get install -y avahi-daemon avahi-utils
  systemctl enable avahi-daemon
  systemctl restart avahi-daemon
}

# ---------------------------
# Packages
# ---------------------------
install_packages() {
  log "[1/9] System update"
  apt-get update -y
  apt-get upgrade -y

  log "[2/9] Base packages"
  apt-get install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev

  log "[3/9] SoapySDR"
  apt-get install -y \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all
}

# ---------------------------
# Sources
# ---------------------------
prepare_dirs() {
  log "[4/9] Prepare directories"
  mkdir -p "$SRC_DIR" "$WEB_ROOT"
}

clone_or_update() {
  local name="$1" url="$2" dest="$SRC_DIR/$name"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --all
    git -C "$dest" reset --hard origin/main || git -C "$dest" reset --hard origin/master
  else
    git clone "$url" "$dest"
  fi
}

build_dump1090() {
  log "[5/9] Build dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  make -C "$SRC_DIR/dump1090" -j"$(nproc)" ENABLE_SOAPYSDR=yes
  install -m755 "$SRC_DIR/dump1090/dump1090" /usr/local/bin/dump1090-fa
}

build_dump978() {
  log "[6/9] Build dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  make -C "$SRC_DIR/dump978" clean || true
  make -C "$SRC_DIR/dump978" -j"$(nproc)"
  install -m755 "$SRC_DIR/dump978/dump978-fa" /usr/local/bin/dump978-fa
}

# ---------------------------
# Runtime dirs
# ---------------------------
setup_tmpfiles() {
  log "[7/9] Runtime dirs"
  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF
  systemd-tmpfiles --create
}

# ---------------------------
# Services
# ---------------------------
install_services() {
  log "Install SDR services"

  install -m644 "$REPO_ROOT/systemd/"*.service /etc/systemd/system/

  cat > /etc/default/dump1090-fa <<EOF
DUMP1090_ARGS="--device-type rtlsdr --device-index 0 \
--net --write-json $RUN_DIR/dump1090 --write-json-every 1"
EOF

  cat > /etc/default/dump978-fa <<EOF
DUMP978_ARGS="--sdr driver=rtlsdr,index=1 --json-stdout"
EOF

  systemctl daemon-reload
  systemctl enable dump1090-fa dump978-fa homebase-boot
}

# ---------------------------
# Networking (fallback AP)
# ---------------------------
install_networking() {
  log "Install Homebase networking"

  install -m644 "$REPO_ROOT/network/dhcpcd-homebase.conf" /etc/dhcpcd.conf.d/homebase.conf
  install -m644 "$REPO_ROOT/network/dnsmasq-homebase.conf" /etc/dnsmasq.d/homebase.conf
  install -m644 "$REPO_ROOT/network/hostapd.conf" /etc/hostapd/hostapd.conf

  sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
}

# ---------------------------
# Web
# ---------------------------
deploy_web() {
  log "Deploy Homebase web UI"
  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"

  mkdir -p "$WEB_ROOT/feeds"

  cat > "$WEB_ROOT/feeds/combined.php" <<EOF
<?php
header('Content-Type: application/json');
echo json_encode([
  'adsb' => @json_decode(@file_get_contents('$RUN_DIR/dump1090/aircraft.json'), true),
  'uat'  => @json_decode(@file_get_contents('$RUN_DIR/dump978/latest.json'), true),
  'generated' => gmdate('c')
]);
EOF

  local sock
  sock="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  root $WEB_ROOT;
  index index.php;
  location / { try_files \$uri \$uri/ /index.php; }
  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:$sock;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl restart nginx
}

# ---------------------------
# Self-test
# ---------------------------
selftest() {
  log "[9/9] Self-test"
  hostname
  SoapySDRUtil --info | head -n5 || true
  systemctl is-enabled dump1090-fa dump978-fa homebase-boot
  curl -sf http://localhost/feeds/combined.php || true
}

# ---------------------------
# Run
# ---------------------------
require_root
install_identity
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_services
install_networking
deploy_web
selftest

log "Install complete"
echo "Access via: http://homebase.local or AP 192.168.4.1"