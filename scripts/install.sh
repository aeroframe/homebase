#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# FINAL STABLE DESIGN:
# - No hotspot
# - No network switching
# - Ethernet or preconfigured Wi-Fi only
# - SSH always works
# - homebase.local via Avahi
# - Services survive reboot
# - SDR hardware optional
############################################################

TARGET_HOSTNAME="homebase"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_SRC="${REPO_ROOT}/systemd"

SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"
LOG_FILE="/var/log/homebase-install.log"

############################################################
# Helpers
############################################################
log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 2
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true
}

ensure_php_fpm() {
  if systemctl list-unit-files | grep -q '^php-fpm\.service'; then
    systemctl enable --now php-fpm
  else
    local svc
    svc="$(systemctl list-unit-files | awk '{print $1}' | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' | sort -V | tail -n1)"
    [[ -n "$svc" ]] && systemctl enable --now "$svc"
  fi
  sleep 2
}

############################################################
# 0. Baseline
############################################################
baseline() {
  log "[0/7] Baseline system"

  apt_run update -y
  apt_run install -y \
    openssh-server \
    avahi-daemon avahi-utils \
    locales

  systemctl enable --now ssh
  systemctl enable --now avahi-daemon

  # Locale
  if ! locale -a | grep -qi en_GB.utf8; then
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
  fi

  hostnamectl set-hostname "$TARGET_HOSTNAME"

  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi
}

############################################################
# 1. Packages
############################################################
packages() {
  log "[1/7] Installing packages"

  apt_run update -y
  apt_run upgrade -y

  apt_run install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all
}

############################################################
# 2. Directories
############################################################
dirs() {
  log "[2/7] Creating directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 3. SDR Builds (non-fatal)
############################################################
clone_or_update() {
  local name="$1" url="$2" dest="$SRC_DIR/$name"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --all --prune
    git -C "$dest" reset --hard origin/main || git -C "$dest" reset --hard origin/master
  else
    git clone "$url" "$dest"
  fi
}

build_sdr() {
  log "[3/7] Building SDR tools (safe)"

  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  (cd "$SRC_DIR/dump1090" && make -j$(nproc) && install -m755 dump1090 /usr/local/bin/dump1090-fa) || true

  clone_or_update dump978 https://github.com/flightaware/dump978.git
  (cd "$SRC_DIR/dump978" && make clean && make -j$(nproc) && install -m755 dump978-fa /usr/local/bin/dump978-fa) || true
}

############################################################
# 4. Runtime dirs
############################################################
runtime_dirs() {
  log "[4/7] Runtime dirs"

  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# 5. systemd services
############################################################
services() {
  log "[5/7] Installing systemd units"

  install -d /etc/systemd/system
  rsync -a "$SYSTEMD_SRC/" /etc/systemd/system/

  systemctl daemon-reload

  # IMPORTANT: enable for boot
  systemctl enable nginx
  systemctl enable dump1090-fa dump978-fa || true
}

############################################################
# 6. Web + nginx
############################################################
web() {
  log "[6/7] Deploy web app"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  ensure_php_fpm
  PHP_SOCK="$(detect_php_sock)"

  rm -f /etc/nginx/sites-enabled/default

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root $WEB_ROOT;
  index index.php index.html;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:$PHP_SOCK;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase

  nginx -t
  systemctl restart nginx
}

############################################################
# Run
############################################################
require_root
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

baseline
packages
dirs
build_sdr
runtime_dirs
services
web

log "INSTALL COMPLETE"
log "Reboot recommended"
log "Homebase:"
log "  http://homebase.local/"
log "  http://$(hostname -I | awk '{print $1}')/"