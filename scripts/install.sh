#!/usr/bin/env bash
set -euo pipefail

# ========================================
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian Trixie / 64-bit
# ========================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"
HOSTNAME="homebase"

log() {
  echo -e "\n[$(date '+%H:%M:%S')] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run with sudo: sudo ./scripts/install.sh"
    exit 1
  fi
}

# ---------------------------
# APT LOCK SAFETY (CRITICAL)
# ---------------------------
wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[install] Waiting for apt lock..."
    sleep 3
  done
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
# SSH SAFETY (NEVER BREAK)
# ---------------------------
ensure_ssh() {
  log "Ensure SSH access (critical)"
  wait_for_apt
  apt-get update -y
  apt-get install -y openssh-server
  systemctl enable ssh
  systemctl restart ssh
}

# ---------------------------
# Hostname + mDNS
# ---------------------------
setup_mdns() {
  log "Configure hostname + mDNS (${HOSTNAME}.local)"
  wait_for_apt
  apt-get install -y avahi-daemon avahi-utils

  hostnamectl set-hostname "${HOSTNAME}"

  systemctl enable avahi-daemon
  systemctl restart avahi-daemon
}

# ---------------------------
# Packages
# ---------------------------
install_packages() {
  log "[1/9] System update"
  wait_for_apt
  apt-get update -y
  apt-get upgrade -y

  log "[2/9] Base packages"
  wait_for_apt
  apt-get install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev

  log "[3/9] SoapySDR"
  wait_for_apt
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
# Git helper
# ---------------------------
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/main || \
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
  log "Install systemd services"

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
  log "Deploy web UI"
  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"

  install -d "${WEB_ROOT}/feeds"

  cat > "${WEB_ROOT}/feeds/combined.php" <<'EOF'
<?php
header('Content-Type: application/json');

echo json_encode([
  'generated_at' => gmdate('c'),
  'dump1090' => @json_decode(@file_get_contents('/run/homebase/dump1090/aircraft.json'), true),
  'dump978'  => @json_decode(@file_get_contents('/run/homebase/dump978/latest.json'), true),
]);
EOF
}

install_nginx_site() {
  log "Configure nginx"

  PHP_SOCK="$(ls -1 /run/php/php*-fpm.sock | sort -V | tail -n 1)"

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
    fastcgi_pass unix:${PHP_SOCK};
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
  systemctl is-active ssh >/dev/null && echo "✔ SSH active"
  systemctl is-active nginx >/dev/null && echo "✔ nginx active"
  systemctl is-enabled dump1090-fa >/dev/null && echo "✔ dump1090 enabled"
  systemctl is-enabled dump978-fa >/dev/null && echo "✔ dump978 enabled"

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
ensure_ssh
setup_mdns
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_systemd_units
deploy_web_app
install_nginx_site
self_test