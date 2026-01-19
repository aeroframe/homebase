#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# Design:
# - Plug-and-play
# - Ethernet or managed Wi-Fi only
# - mDNS via homebase.local
# - NO hotspot / NO wlan manipulation
############################################################

TARGET_HOSTNAME="homebase"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"
LOG_FILE="/var/log/homebase-install.log"

############################################################
# Helpers
############################################################
log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }; }

wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    [[ $waited -ge 300 ]] && { echo "apt lock timeout"; exit 1; }
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

ensure_php_fpm_running() {
  local svc
  svc="$(systemctl list-unit-files | awk '{print $1}' | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' | sort -V | tail -n 1 || true)"
  [[ -n "$svc" ]] && systemctl enable --now "$svc" || true
  sleep 2
}

############################################################
# 0. Baseline system
############################################################
baseline_system() {
  log "[0/8] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh

  sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen || true
  locale-gen || true

  hostnamectl set-hostname "$TARGET_HOSTNAME"

  sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts \
    || echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts

  systemctl restart systemd-hostnamed avahi-daemon || true
}

############################################################
# 1. Git safety
############################################################
git_safety() {
  log "[1/8] Git safety"
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "$REPO_ROOT" || true
}

############################################################
# 2. Packages
############################################################
install_packages() {
  log "[2/8] Installing packages"

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
# 3. Directories
############################################################
prepare_dirs() {
  log "[3/8] Directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 4. SDR builds (non-blocking)
############################################################
clone_or_update() {
  local name="$1" url="$2" dest="$SRC_DIR/$name"
  [[ -d "$dest/.git" ]] && git -C "$dest" reset --hard origin/main || git clone "$url" "$dest"
}

build_sdr() {
  log "[4/8] SDR builds"

  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  make -C "$SRC_DIR/dump1090" -j$(nproc) || true
  [[ -f "$SRC_DIR/dump1090/dump1090" ]] && install -m755 "$SRC_DIR/dump1090/dump1090" /usr/local/bin/dump1090-fa || true

  clone_or_update dump978 https://github.com/flightaware/dump978.git
  make -C "$SRC_DIR/dump978" clean || true
  make -C "$SRC_DIR/dump978" -j$(nproc) || true
  [[ -f "$SRC_DIR/dump978/dump978-fa" ]] && install -m755 "$SRC_DIR/dump978/dump978-fa" /usr/local/bin/dump978-fa || true
}

############################################################
# 5. Runtime dirs
############################################################
runtime_dirs() {
  log "[5/8] Runtime dirs"

  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF

  systemd-tmpfiles --create || true
}

############################################################
# 6. Services
############################################################
install_services() {
  log "[6/8] Services"

  cat > /etc/systemd/system/dump1090-fa.service <<EOF
[Service]
ExecStart=/usr/local/bin/dump1090-fa --net --write-json $RUN_DIR/dump1090
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dump978-fa.service <<EOF
[Service]
ExecStart=/usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dump1090-fa dump978-fa || true
}

############################################################
# 7. Web UI
############################################################
deploy_web() {
  log "[7/8] Web UI"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  ensure_php_fpm_running
  PHP_SOCK="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  root $WEB_ROOT;
  index index.php index.html;

  location / { try_files \$uri /index.php; }
  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:$PHP_SOCK;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl enable --now nginx || true
}

############################################################
# 8. Self-test
############################################################
self_test() {
  log "[8/8] Self-test"

  echo "✔ SSH: $(systemctl is-active ssh)"
  echo "✔ Avahi: $(systemctl is-active avahi-daemon)"
  echo "✔ Web: http://homebase.local"
  echo "✔ IP: $(hostname -I | awk '{print $1}')"
}

############################################################
# RUN
############################################################
require_root
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

baseline_system
git_safety
install_packages
prepare_dirs
build_sdr
runtime_dirs
install_services
deploy_web
self_test