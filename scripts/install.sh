#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# FINAL DESIGN:
# - NO hotspot
# - NO network switching
# - SSH always works
# - Services persist across reboot
# - homebase.local via Avahi
# - SDR optional (non-blocking)
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
  [[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./scripts/install.sh"; exit 1; }
}

wait_for_apt() {
  local waited=0
  while \
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
    fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
    fuser /var/cache/apt/archives/lock >/dev/null 2>&1 || \
    fuser /var/lib/apt/lists/lock >/dev/null 2>&1
  do
    sleep 2
    waited=$((waited + 2))
    [[ $waited -ge 300 ]] && {
      echo "ERROR: apt lock stuck. Reboot and retry."
      exit 1
    }
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

############################################################
# 0. Baseline
############################################################
baseline_system() {
  log "[0/7] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh avahi-daemon

  # Locale fix
  if ! locale -a | grep -qi '^en_GB\.utf8$'; then
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
install_packages() {
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
prepare_dirs() {
  log "[2/7] Creating directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 3. SDR builds (NON-BLOCKING)
############################################################
clone_or_update() {
  local repo="$1" url="$2" dest="$SRC_DIR/$repo"
  [[ -d "$dest/.git" ]] && \
    git -C "$dest" reset --hard origin/main || git clone "$url" "$dest" || true
}

build_dump1090() {
  log "[3/7] dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  make -C "$SRC_DIR/dump1090" -j$(nproc) && \
    install -m755 "$SRC_DIR/dump1090/dump1090" /usr/local/bin/dump1090-fa || true
}

build_dump978() {
  log "[4/7] dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  make -C "$SRC_DIR/dump978" clean || true
  make -C "$SRC_DIR/dump978" -j$(nproc) && \
    install -m755 "$SRC_DIR/dump978/dump978-fa" /usr/local/bin/dump978-fa || true
}

############################################################
# 4. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[5/7] Runtime directories"
  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF
  systemd-tmpfiles --create
}

############################################################
# 5. systemd services (BOOT FIX)
############################################################
install_services() {
  log "[6/7] Installing & enabling services"

  install -d /etc/systemd/system
  rsync -a "$SYSTEMD_SRC_DIR/" /etc/systemd/system/ --include='*.service' --exclude='*'

  systemctl daemon-reload

  # CORE SERVICES
  systemctl enable ssh avahi-daemon nginx

  # PHP-FPM (version safe)
  if systemctl list-unit-files | grep -q '^php-fpm\.service'; then
    systemctl enable php-fpm
  else
    PHP_SVC=$(systemctl list-unit-files | grep -E '^php[0-9]+\.[0-9]+-fpm\.service' | sort -V | tail -n1 || true)
    [[ -n "$PHP_SVC" ]] && systemctl enable "$PHP_SVC"
  fi

  # SDR SERVICES (NON-BLOCKING)
  systemctl enable dump1090-fa dump978-fa || true

  # START NOW (mirrors boot behavior)
  systemctl start ssh avahi-daemon nginx
  systemctl start dump1090-fa dump978-fa || true
}

############################################################
# 6. Web UI
############################################################
deploy_web() {
  log "[7/7] Deploy web UI"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  PHP_SOCK="$(detect_php_sock)"
  [[ -z "$PHP_SOCK" ]] && { echo "PHP-FPM socket missing"; exit 1; }

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

log "DONE"
log "Homebase ready after reboot at:"
log "  http://homebase.local/"
log "  http://$(hostname -I | awk '{print $1}')/"