#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# FINAL, STABLE, REBOOT-SAFE DESIGN
#
# - No hotspot
# - No network switching
# - SSH always preserved
# - nginx + avahi + services survive reboot
# - homebase.local works after reboot
# - SDR optional (services tolerate missing hardware)
# - Single SDR safety: do NOT run 1090 + 978 simultaneously
#
# Systemd units live in repo: /systemd
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
  while fuser /var/lib/dpkg/lock* /var/cache/apt/archives/lock \
        /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    [[ $waited -gt 300 ]] && { echo "ERROR: apt lock timeout"; exit 1; }
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true
}

ensure_php_fpm_running() {
  log "Ensuring PHP-FPM is running"

  local svc
  svc="$(systemctl list-unit-files | awk '{print $1}' \
    | grep -E '^php.*-fpm\.service$' \
    | sort -V | tail -n1 || true)"

  [[ -n "$svc" ]] && systemctl enable --now "$svc"

  for _ in {1..10}; do
    [[ -S "$(detect_php_sock)" ]] && return 0
    sleep 1
  done

  echo "ERROR: PHP-FPM socket not found"
  exit 1
}

############################################################
# 0. Baseline system
############################################################
baseline_system() {
  log "[0/9] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh avahi-daemon

  # Locale fix (silences perl warnings)
  if ! locale -a | grep -qi en_GB.utf8; then
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
  fi

  hostnamectl set-hostname "$TARGET_HOSTNAME"

  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 $TARGET_HOSTNAME/" /etc/hosts
  else
    echo "127.0.1.1 $TARGET_HOSTNAME" >> /etc/hosts
  fi
}

############################################################
# 1. Packages
############################################################
install_packages() {
  log "[1/9] Installing packages"

  apt_run update -y
  apt_run upgrade -y

  apt_run install -y \
    git curl ca-certificates rsync lsof usbutils \
    nginx php-fpm \
    python3 python3-pip \
    build-essential cmake pkg-config \
    libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    librtlsdr-dev rtl-sdr \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all
}

############################################################
# 2. SDR kernel driver safety (prevents DVB from stealing RTL)
############################################################
configure_rtlsdr_blacklist() {
  log "[2/9] Configure RTL-SDR DVB blacklist (prevents tuner claim)"

  cat > /etc/modprobe.d/rtl-sdr-blacklist.conf <<'EOF'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

  # Try unloading if already loaded; ignore if not present.
  modprobe -r dvb_usb_rtl28xxu rtl2832 rtl2830 2>/dev/null || true
}

############################################################
# 3. Directories
############################################################
prepare_dirs() {
  log "[3/9] Creating directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 4. SDR builds (safe if hardware missing)
############################################################
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="$SRC_DIR/$name"

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --all --prune
    git -C "$dest" reset --hard origin/main 2>/dev/null || \
    git -C "$dest" reset --hard origin/master || true
  else
    git clone "$url" "$dest" || true
  fi
}

build_dump1090() {
  log "[4/9] Building dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  pushd "$SRC_DIR/dump1090" >/dev/null || return 0
  make -j"$(nproc)" && install -m755 dump1090 /usr/local/bin/dump1090-fa || true
  popd >/dev/null || true
}

build_dump978() {
  log "[5/9] Building dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  pushd "$SRC_DIR/dump978" >/dev/null || return 0
  make clean || true
  make -j"$(nproc)" && install -m755 dump978-fa /usr/local/bin/dump978-fa || true
  popd >/dev/null || true
}

############################################################
# 5. Runtime dirs (tmpfiles, reboot-safe)
############################################################
setup_tmpfiles() {
  log "[6/9] Runtime dirs"

  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# 6. systemd services (from repo)
############################################################
install_services() {
  log "[7/9] Installing systemd units"

  if [[ ! -d "$SYSTEMD_SRC_DIR" ]]; then
    echo "ERROR: Missing /systemd directory in repo"
    exit 1
  fi

  rsync -a \
    --include='*.service' \
    --exclude='*' \
    "$SYSTEMD_SRC_DIR/" \
    /etc/systemd/system/

  systemctl daemon-reload

  # Always keep core services enabled
  systemctl enable nginx avahi-daemon homebase-avahi-fix 2>/dev/null || true

  # SDR services are installed, but we only enable 1090 by default (single SDR safe)
  systemctl enable dump1090-fa 2>/dev/null || true
  systemctl disable dump978-fa 2>/dev/null || true
}

############################################################
# 7. Web UI + nginx
############################################################
deploy_web() {
  log "[8/9] Deploying web UI"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  ensure_php_fpm_running
  local PHP_SOCK
  PHP_SOCK="$(detect_php_sock)"

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
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
}

############################################################
# 8. Start services (single SDR safe)
############################################################
start_services() {
  log "[9/9] Starting services"

  systemctl restart avahi-daemon
  systemctl restart nginx

  # SDR: default to 1090 only (users can switch to 978 later)
  systemctl restart dump1090-fa || true
  systemctl stop dump978-fa 2>/dev/null || true

  log "Post-install SDR check:"
  if lsusb | grep -qiE '0bda:2832|rtl|realtek'; then
    echo "✔ RTL-SDR detected via lsusb"
  else
    echo "⚠ No RTL-SDR detected (ok if you haven't plugged one in yet)"
  fi
}

############################################################
# RUN
############################################################
require_root
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

baseline_system
install_packages
configure_rtlsdr_blacklist
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_services
deploy_web
start_services

log "INSTALL COMPLETE"
log "Access:"
log "  http://homebase.local/"
log "  http://$(hostname -I | awk '{print $1}')"
log "Reboot-safe: YES"
log "Default ADS-B mode: 1090"
log "To switch to 978 later:"
log "  sudo systemctl stop dump1090-fa && sudo systemctl start dump978-fa"