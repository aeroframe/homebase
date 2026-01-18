#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# Homebase Installer (Aeroframe)
# Raspberry Pi / Debian (Trixie) / 64-bit
# ----------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

log() {
  echo -e "\n[$(date '+%H:%M:%S')] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run with sudo: sudo ./scripts/install.sh"
    exit 1
  fi
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

main_banner() {
  echo "======================================"
  echo " Homebase Beta Installer (Aeroframe)"
  echo " Raspberry Pi 4 / 64-bit OS"
  echo "======================================"
}

# ---------------------------
# Git safety
# ---------------------------
fix_repo_ownership() {
  log "Trust repo ownership (avoids dubious ownership)"
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "${REPO_ROOT}" || true
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
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    avahi-daemon avahi-utils

  log "[3/9] SoapySDR"
  apt-get install -y \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all || true
}

# ---------------------------
# Directories
# ---------------------------
prepare_dirs() {
  log "[4/9] Prepare directories"
  install -d "${SRC_DIR}"
  install -d "${WEB_ROOT}"
}

# ---------------------------
# Git helper (FIXED)
# ---------------------------
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/main 2>/dev/null || \
    git -C "${dest}" reset --hard origin/master
  else
    log "Cloning ${name}"
    git clone "${url}" "${dest}"
  fi
}

# ---------------------------
# Build dump1090-fa
# ---------------------------
build_dump1090() {
  log "[5/9] Build dump1090-fa"
  clone_or_update "dump1090" "https://github.com/flightaware/dump1090.git"
  pushd "${SRC_DIR}/dump1090" >/dev/null
  make -j"$(nproc)"
  install -m 755 dump1090 /usr/local/bin/dump1090-fa
  popd >/dev/null
}

# ---------------------------
# Build dump978-fa
# ---------------------------
build_dump978() {
  log "[6/9] Build dump978-fa"
  clone_or_update "dump978" "https://github.com/flightaware/dump978.git"
  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean || true
  make -j"$(nproc)"
  install -m 755 dump978-fa /usr/local/bin/dump978-fa
  popd >/dev/null
}

# ---------------------------
# Runtime dirs
# ---------------------------
setup_tmpfiles() {
  log "[7/9] Runtime directories"
  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF
  systemd-tmpfiles --create
}

# ---------------------------
# Systemd services
# ---------------------------
install_systemd_units() {
  log "Installing systemd services"

  install -m 644 "${REPO_ROOT}/systemd/homebase-normal.service" /etc/systemd/system/
  install -m 644 "${REPO_ROOT}/systemd/homebase-hotspot.service" /etc/systemd/system/
  install -m 644 "${REPO_ROOT}/systemd/homebase-boot.service" /etc/systemd/system/

  cat > /etc/systemd/system/dump1090-fa.service <<'EOF'
[Unit]
Description=Homebase dump1090-fa
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dump1090-fa --net --write-json /run/homebase/dump1090
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dump978-fa.service <<'EOF'
[Unit]
Description=Homebase dump978-fa
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dump1090-fa dump978-fa homebase-boot
  systemctl restart dump1090-fa dump978-fa || true
}

# ---------------------------
# Web UI
# ---------------------------
deploy_web_app() {
  log "Deploying web UI"
  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"

  install -d "${WEB_ROOT}/feeds"

  cat > "${WEB_ROOT}/feeds/combined.php" <<'EOF'
<?php
header('Content-Type: application/json');

$out = [
  'generated_at' => gmdate('c'),
  'dump1090' => @json_decode(@file_get_contents('/run/homebase/dump1090/aircraft.json'), true),
  'dump978'  => @json_decode(@file_get_contents('/run/homebase/dump978/latest.json'), true),
];

echo json_encode($out);
EOF
}

install_nginx_site() {
  log "Configuring nginx"

  local php_sock
  php_sock="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  root ${WEB_ROOT};
  index index.php;

  location / {
    try_files \$uri \$uri/ /index.php;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${php_sock};
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl restart nginx
}

# ---------------------------
# Self-test
# ---------------------------
self_test() {
  log "[9/9] Self-test"

  command -v dump1090-fa >/dev/null && echo "✔ dump1090-fa"
  command -v dump978-fa >/dev/null && echo "✔ dump978-fa"
  systemctl is-enabled dump1090-fa >/dev/null && echo "✔ dump1090 service"
  systemctl is-enabled dump978-fa >/dev/null && echo "✔ dump978 service"
  systemctl is-active nginx >/dev/null && echo "✔ nginx"

  echo
  echo "Homebase ready:"
  echo "  http://homebase.local/"
  echo "  http://<PI_IP>/feeds/combined.php"
}

# ---------------------------
# Run
# ---------------------------
require_root
main_banner
fix_repo_ownership
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_systemd_units
deploy_web_app
install_nginx_site
self_test