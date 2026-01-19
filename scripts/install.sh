#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# FINAL BOOT-SAFE VERSION
############################################################

TARGET_HOSTNAME="homebase"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_SRC_DIR="${REPO_ROOT}/systemd"

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
  local waited=0
  while fuser /var/lib/dpkg/lock* /var/cache/apt/archives/lock \
        /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
    waited=$((waited+2))
    [[ $waited -gt 300 ]] && { echo "apt lock timeout"; exit 1; }
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true
}

############################################################
# PHP-FPM
############################################################
ensure_php_fpm_running() {
  log "Ensuring PHP-FPM is running"

  local php_svc
  php_svc="$(systemctl list-unit-files | awk '{print $1}' \
    | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' \
    | sort -V | tail -n1)"

  systemctl enable --now "$php_svc"

  for _ in {1..15}; do
    [[ -S "$(detect_php_sock)" ]] && return 0
    sleep 1
  done

  echo "ERROR: PHP-FPM socket not found"
  exit 1
}

############################################################
# nginx boot fix
############################################################
fix_nginx_boot() {
  log "Fixing nginx boot order"

  local php_svc
  php_svc="$(systemctl list-unit-files | awk '{print $1}' \
    | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' \
    | sort -V | tail -n1)"

  mkdir -p /etc/systemd/system/nginx.service.d

  cat > /etc/systemd/system/nginx.service.d/override.conf <<EOF
[Unit]
After=network-online.target ${php_svc}
Requires=${php_svc}

[Service]
Restart=always
RestartSec=3
EOF

  systemctl daemon-reload
  systemctl enable nginx
}

############################################################
# Baseline system
############################################################
baseline_system() {
  log "[0/8] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh avahi-daemon

  hostnamectl set-hostname "$TARGET_HOSTNAME"

  sed -i "s/^127.0.1.1.*/127.0.1.1 $TARGET_HOSTNAME/" /etc/hosts || true
}

############################################################
# Packages
############################################################
install_packages() {
  log "[1/8] Installing packages"

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
# Directories
############################################################
prepare_dirs() {
  log "[2/8] Creating directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# SDR builds (FIXED)
############################################################
clone_or_update() {
  local repo
  local url
  local dest

  repo="$1"
  url="$2"
  dest="$SRC_DIR/$repo"

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --rebase || true
  else
    git clone "$url" "$dest" || true
  fi
}

build_dump1090() {
  log "[3/8] dump1090"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  cd "$SRC_DIR/dump1090" || return 0
  make -j"$(nproc)" && install -m755 dump1090 /usr/local/bin/dump1090-fa || true
}

build_dump978() {
  log "[4/8] dump978"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  cd "$SRC_DIR/dump978" || return 0
  make clean || true
  make -j"$(nproc)" && install -m755 dump978-fa /usr/local/bin/dump978-fa || true
}

############################################################
# Runtime dirs
############################################################
setup_tmpfiles() {
  log "[5/8] Runtime dirs"

  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# systemd services
############################################################
install_services() {
  log "[6/8] Installing systemd units"

  rsync -a "$SYSTEMD_SRC_DIR/" /etc/systemd/system/
  systemctl daemon-reload

  systemctl enable nginx dump1090-fa dump978-fa
}

############################################################
# Web
############################################################
deploy_web() {
  log "[7/8] Web + nginx"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  ensure_php_fpm_running
  fix_nginx_boot

  local PHP_SOCK
  PHP_SOCK="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
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
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl restart nginx
}

############################################################
# RUN
############################################################
require_root
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

baseline_system
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_services
deploy_web

log "INSTALL COMPLETE"
log "Reboot-safe: YES"
log "http://homebase.local/"
log "http://$(hostname -I | awk '{print $1}')"