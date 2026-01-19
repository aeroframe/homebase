#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# DESIGN (FINAL-FIXED):
# - NO hotspot
# - NO network switching
# - Works on Ethernet or preconfigured Wi-Fi
# - SSH is never disrupted
# - homebase.local via Avahi/mDNS (forced publish)
# - SDR hardware optional (services never block boot)
#
# NOTE:
# - Systemd unit templates live in the repo at: /systemd
# - This installer copies them to: /etc/systemd/system
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
    if [[ $waited -ge 300 ]]; then
      echo "ERROR: apt/dpkg lock still held after ${waited}s."
      echo "Try: sudo systemctl stop unattended-upgrades || true"
      echo "Or reboot once and re-run."
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

ensure_php_fpm_running() {
  log "Ensuring PHP-FPM is enabled and running"

  if systemctl list-unit-files | grep -q '^php-fpm\.service'; then
    systemctl enable --now php-fpm >/dev/null 2>&1 || true
  else
    local svc
    svc="$(systemctl list-unit-files | awk '{print $1}' \
      | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' \
      | sort -V | tail -n 1 || true)"
    [[ -n "${svc}" ]] && systemctl enable --now "${svc}" >/dev/null 2>&1 || true
  fi

  # Give time for the socket to appear
  sleep 2
}

disable_apt_timers() {
  log "Disabling background apt timers/services (prevents dpkg lock conflicts)"
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}

############################################################
# 0. Baseline system
############################################################
baseline_system() {
  log "[0/7] Baseline system (SSH + Avahi/mDNS + hostname + locale)"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  # SSH: enable & start (independent of hostname/mDNS)
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl start ssh  >/dev/null 2>&1 || true

  # Locale fix (kills perl warnings on fresh images)
  if ! locale -a | grep -qi '^en_GB\.utf8$'; then
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen >/dev/null 2>&1 || true
  fi

  # Hostname + /etc/hosts mapping (prevents "sudo: unable to resolve host")
  hostnamectl set-hostname "${TARGET_HOSTNAME}" >/dev/null 2>&1 || true

  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi

  # Force Avahi to publish hostname reliably (key fix for homebase.local resolution)
  if [[ -f /etc/avahi/avahi-daemon.conf ]]; then
    sed -i 's/^#\?publish-hostname=.*/publish-hostname=yes/' /etc/avahi/avahi-daemon.conf || true
    sed -i 's/^#\?use-ipv4=.*/use-ipv4=yes/' /etc/avahi/avahi-daemon.conf || true
    sed -i 's/^#\?use-ipv6=.*/use-ipv6=no/' /etc/avahi/avahi-daemon.conf || true
  fi

  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl restart systemd-hostnamed >/dev/null 2>&1 || true
  systemctl restart avahi-daemon       >/dev/null 2>&1 || true
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
  install -d "${SRC_DIR}" "${WEB_ROOT}" "${RUN_DIR}"
}

############################################################
# 3. SDR builds (safe if hardware missing)
############################################################
clone_or_update() {
  local repo="$1"
  local url="$2"
  local dest="${SRC_DIR}/${repo}"

  if [[ -d "${dest}/.git" ]]; then
    git -C "${dest}" fetch --all --prune >/dev/null 2>&1 || true
    git -C "${dest}" reset --hard origin/main   >/dev/null 2>&1 || \
    git -C "${dest}" reset --hard origin/master >/dev/null 2>&1 || true
  else
    git clone "${url}" "${dest}" >/dev/null 2>&1 || true
  fi
}

build_dump1090() {
  log "[3/7] Building dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git

  if [[ ! -d "${SRC_DIR}/dump1090" ]]; then
    echo "WARN: dump1090 source not present; skipping"
    return 0
  fi

  pushd "${SRC_DIR}/dump1090" >/dev/null
  if make -j"$(nproc)"; then
    [[ -f dump1090 ]] && install -m 755 dump1090 /usr/local/bin/dump1090-fa || true
  else
    echo "WARN: dump1090 build failed (continuing)"
  fi
  popd >/dev/null
}

build_dump978() {
  log "[4/7] Building dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git

  if [[ ! -d "${SRC_DIR}/dump978" ]]; then
    echo "WARN: dump978 source not present; skipping"
    return 0
  fi

  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean >/dev/null 2>&1 || true
  if make -j"$(nproc)"; then
    [[ -f dump978-fa ]] && install -m 755 dump978-fa /usr/local/bin/dump978-fa || true
  else
    echo "WARN: dump978 build failed (continuing)"
  fi
  popd >/dev/null
}

############################################################
# 4. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[5/7] Runtime directories"
  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF
  systemd-tmpfiles --create >/dev/null 2>&1 || true
}

############################################################
# 5. systemd services (from repo, but patched for safe boot)
############################################################
write_safe_service_overrides() {
  # Ensure SDR services never block boot:
  # - Remove network-online.target dependency
  # - Start after multi-user.target
  # - Unlimited restart window
  log "Patching SDR units for safe boot (no network-online dependency)"

  # dump1090-fa.service
  cat > /etc/systemd/system/dump1090-fa.service <<EOF
[Unit]
Description=Homebase dump1090-fa
After=multi-user.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/dump1090-fa --net --write-json ${RUN_DIR}/dump1090
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

  # dump978-fa.service
  cat > /etc/systemd/system/dump978-fa.service <<EOF
[Unit]
Description=Homebase dump978-fa
After=multi-user.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
}

install_services() {
  log "[6/7] Installing services from repo (/systemd) + enabling boot"

  if [[ ! -d "${SYSTEMD_SRC_DIR}" ]]; then
    echo "ERROR: Missing ${SYSTEMD_SRC_DIR}"
    echo "Expected systemd units in the repo at /systemd"
    exit 1
  fi

  install -d /etc/systemd/system

  # Copy repo services (if present). We will overwrite the SDR ones with safe versions below.
  rsync -a "${SYSTEMD_SRC_DIR}/" /etc/systemd/system/ \
    --include='*.service' --exclude='*' >/dev/null 2>&1 || true

  # Always ensure required ones exist (safe overrides)
  write_safe_service_overrides

  systemctl daemon-reload

  # Enable for boot persistence (key requirement)
  systemctl enable ssh avahi-daemon nginx dump1090-fa dump978-fa >/dev/null 2>&1 || true
}

############################################################
# 6. Web UI + nginx
############################################################
deploy_web() {
  log "[7/7] Deploying web UI + nginx"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}"

  ensure_php_fpm_running
  local PHP_SOCK
  PHP_SOCK="$(detect_php_sock)"

  if [[ -z "${PHP_SOCK}" ]]; then
    echo "ERROR: PHP-FPM socket not found under /run/php. Is php-fpm installed and running?"
    exit 1
  fi

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root ${WEB_ROOT};
  index index.php index.html;

  add_header X-Content-Type-Options nosniff always;
  add_header X-Frame-Options SAMEORIGIN always;

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

  # Start SDR services now (ok if they fail without hardware; won't block boot)
  systemctl restart dump1090-fa >/dev/null 2>&1 || true
  systemctl restart dump978-fa >/dev/null 2>&1 || true
}

############################################################
# Post-install checks
############################################################
post_checks() {
  log "Post-install checks"
  systemctl is-active ssh         >/dev/null && echo "✔ ssh active"         || echo "✖ ssh not active"
  systemctl is-active avahi-daemon>/dev/null && echo "✔ avahi active"       || echo "✖ avahi not active"
  systemctl is-active nginx       >/dev/null && echo "✔ nginx active"       || echo "✖ nginx not active"

  echo "Enabled at boot:"
  systemctl is-enabled ssh avahi-daemon nginx dump1090-fa dump978-fa 2>/dev/null || true

  local ip
  ip="$(hostname -I | awk '{print $1}')"
  echo
  echo "Homebase URLs:"
  echo "  http://homebase.local/"
  echo "  http://${ip}/"
  echo
  echo "If .local doesn't resolve from your Mac:"
  echo "  - Ensure Mac and Pi are on the same LAN"
  echo "  - On Mac: System Settings > Network > disable/enable Wi-Fi"
}

############################################################
# Run (with logging)
############################################################
require_root
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

disable_apt_timers
baseline_system
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_services
deploy_web
post_checks

log "DONE"