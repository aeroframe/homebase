#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# FINAL STABLE DESIGN
# - NO hotspot
# - NO network switching
# - SSH preserved
# - homebase.local via Avahi/mDNS
# - nginx + PHP-FPM come up after reboot
# - SDR optional (services keep retrying)
#
# Systemd unit templates live in repo: /systemd
# This installer copies them to: /etc/systemd/system
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
require_root() { [[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./scripts/install.sh"; exit 1; }; }

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
    if [[ $waited -ge 300 ]]; then
      echo "ERROR: apt/dpkg lock still held after ${waited}s."
      echo "Try rebooting once and re-running install."
      exit 1
    fi
  done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

detect_php_fpm_service() {
  # Prefer versioned phpX.Y-fpm if present; else php-fpm
  if systemctl list-unit-files | awk '{print $1}' | grep -q '^php[0-9]\+\.[0-9]\+-fpm\.service$'; then
    systemctl list-unit-files | awk '{print $1}' | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' | sort -V | tail -n 1
    return 0
  fi
  if systemctl list-unit-files | awk '{print $1}' | grep -q '^php-fpm\.service$'; then
    echo "php-fpm.service"
    return 0
  fi
  echo ""
}

ensure_php_fpm_running() {
  log "Ensuring PHP-FPM is enabled and running"
  local svc
  svc="$(detect_php_fpm_service)"

  if [[ -z "$svc" ]]; then
    echo "ERROR: Could not find a php-fpm systemd unit (php-fpm or phpX.Y-fpm)."
    exit 1
  fi

  systemctl enable --now "$svc" >/dev/null 2>&1 || true

  # Wait up to 15s for socket to appear
  for _ in {1..15}; do
    local sock
    sock="$(detect_php_sock)"
    if [[ -n "$sock" && -S "$sock" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "ERROR: PHP-FPM socket never appeared under /run/php."
  echo "Try: systemctl status $svc --no-pager"
  exit 1
}

############################################################
# 0. Baseline system
############################################################
baseline_system() {
  log "[0/8] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  # Enable for boot + start now
  systemctl enable --now ssh >/dev/null 2>&1 || true
  systemctl enable --now avahi-daemon >/dev/null 2>&1 || true

  # Locale fix (kills perl warnings on fresh images)
  if ! locale -a | grep -qi '^en_GB\.utf8$'; then
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen >/dev/null 2>&1 || true
  fi

  # Hostname + /etc/hosts mapping
  hostnamectl set-hostname "${TARGET_HOSTNAME}" >/dev/null 2>&1 || true
  sed -i '/^127\.0\.1\.1 /d' /etc/hosts || true
  echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts

  systemctl restart systemd-hostnamed >/dev/null 2>&1 || true
  systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

############################################################
# 1. Packages
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
# 2. Directories
############################################################
prepare_dirs() {
  log "[2/8] Creating directories"
  install -d "${SRC_DIR}" "${WEB_ROOT}" "${RUN_DIR}"
}

############################################################
# 3. SDR builds (optional)
############################################################
clone_or_update() {
  local repo="$1"
  local url="$2"
  local dest="${SRC_DIR}/${repo}"

  if [[ -d "${dest}/.git" ]]; then
    git -C "${dest}" fetch --all --prune >/dev/null 2>&1 || true
    git -C "${dest}" reset --hard origin/main >/dev/null 2>&1 || \
    git -C "${dest}" reset --hard origin/master >/dev/null 2>&1 || true
  else
    git clone "${url}" "${dest}" >/dev/null 2>&1 || true
  fi
}

build_dump1090() {
  log "[3/8] Building dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  pushd "${SRC_DIR}/dump1090" >/dev/null 2>&1 || { echo "WARN: dump1090 src missing"; return 0; }

  if make -j"$(nproc)"; then
    [[ -f dump1090 ]] && install -m 755 dump1090 /usr/local/bin/dump1090-fa || true
  else
    echo "WARN: dump1090 build failed (continuing)"
  fi

  popd >/dev/null 2>&1 || true
}

build_dump978() {
  log "[4/8] Building dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  pushd "${SRC_DIR}/dump978" >/dev/null 2>&1 || { echo "WARN: dump978 src missing"; return 0; }

  make clean >/dev/null 2>&1 || true
  if make -j"$(nproc)"; then
    [[ -f dump978-fa ]] && install -m 755 dump978-fa /usr/local/bin/dump978-fa || true
  else
    echo "WARN: dump978 build failed (continuing)"
  fi

  popd >/dev/null 2>&1 || true
}

############################################################
# 4. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[5/8] Runtime directories"

  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF

  systemd-tmpfiles --create >/dev/null 2>&1 || true
}

############################################################
# 5. systemd services (from repo /systemd, plus hardening)
############################################################
install_services() {
  log "[6/8] Installing systemd units from repo (/systemd)"

  if [[ ! -d "${SYSTEMD_SRC_DIR}" ]]; then
    echo "ERROR: Missing ${SYSTEMD_SRC_DIR}"
    exit 1
  fi

  install -d /etc/systemd/system
  rsync -a "${SYSTEMD_SRC_DIR}/" /etc/systemd/system/ >/dev/null 2>&1 || true

  systemctl daemon-reload

  # Make SDR services “never give up” at boot (optional hardware)
  for svc in dump1090-fa dump978-fa; do
    if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
      # Only add if not already present
      grep -q '^Restart=always' "/etc/systemd/system/${svc}.service" || \
        sed -i '/^\[Service\]/a Restart=always\nRestartSec=5\nStartLimitIntervalSec=0\nExecStartPre=/bin/sleep 5' \
          "/etc/systemd/system/${svc}.service"
    fi
  done

  systemctl daemon-reload

  # Enable for boot
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl enable dump1090-fa dump978-fa >/dev/null 2>&1 || true
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
}

############################################################
# 6. Web UI + nginx site (THIS is what makes homebase.local work)
############################################################
deploy_web_and_nginx_site() {
  log "[7/8] Deploy web UI + configure nginx site"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}"

  ensure_php_fpm_running
  local PHP_SOCK
  PHP_SOCK="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root ${WEB_ROOT};
  index index.php index.html;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${PHP_SOCK};
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1 || true

  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

############################################################
# 7. Start services now (and they’ll be enabled for reboot)
############################################################
start_services() {
  log "[8/8] Starting services"

  systemctl restart avahi-daemon >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true

  # SDR services may fail without hardware; that’s OK now (they will retry)
  systemctl restart dump1090-fa >/dev/null 2>&1 || true
  systemctl restart dump978-fa >/dev/null 2>&1 || true
}

############################################################
# RUN
############################################################
require_root
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

baseline_system
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_services
deploy_web_and_nginx_site
start_services

log "INSTALL COMPLETE"
log "Access:"
log "  http://homebase.local/"
log "  http://$(hostname -I | awk '{print $1}')/"
log ""
log "Boot persistence (should be enabled):"
log "  systemctl is-enabled nginx avahi-daemon dump1090-fa dump978-fa"