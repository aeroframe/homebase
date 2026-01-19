#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
############################################################

TARGET_HOSTNAME="homebase"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

############################################################
# Helpers
############################################################
log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run with sudo: sudo ./scripts/install.sh"
    exit 1
  fi
}

wait_for_apt() {
  log "Waiting for apt/dpkg locks..."
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
  done
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

############################################################
# 0. Baseline system (SAFE)
############################################################
baseline_system() {
  log "[0/9] Baseline system (SSH + hostname + mDNS)"

  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server \
    avahi-daemon \
    avahi-utils

  systemctl enable ssh
  systemctl start ssh

  CURRENT_HOST="$(hostname)"
  if [[ "${CURRENT_HOST}" != "${TARGET_HOSTNAME}" ]]; then
    log "Setting hostname → ${TARGET_HOSTNAME}"
    hostnamectl set-hostname "${TARGET_HOSTNAME}"
  fi

  if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi

  systemctl restart systemd-hostnamed
  systemctl restart avahi-daemon
}

############################################################
# 1. Git safety
############################################################
git_safety() {
  log "[1/9] Git safe.directory"
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "${REPO_ROOT}" || true
}

############################################################
# 2. Packages (SINGLE apt phase)
############################################################
install_packages() {
  log "[2/9] Installing packages"

  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all
}

############################################################
# 3. Directories
############################################################
prepare_dirs() {
  log "[3/9] Creating directories"
  install -d "${SRC_DIR}" "${WEB_ROOT}" "${RUN_DIR}"
}

############################################################
# 4. SDR builds
############################################################
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/main || \
    git -C "${dest}" reset --hard origin/master
  else
    git clone "${url}" "${dest}"
  fi
}

build_dump1090() {
  log "[4/9] Build dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  pushd "${SRC_DIR}/dump1090" >/dev/null
  make -j"$(nproc)"
  install -m 755 dump1090 /usr/local/bin/dump1090-fa
  popd >/dev/null
}

build_dump978() {
  log "[5/9] Build dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean || true
  make -j"$(nproc)"
  install -m 755 dump978-fa /usr/local/bin/dump978-fa
  popd >/dev/null
}

############################################################
# 5. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[6/9] Runtime directories"

  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# 6. systemd services (NO HOTSPOT AUTO-ENABLE)
############################################################
install_systemd_units() {
  log "[7/9] systemd services"

  cat > /etc/systemd/system/dump1090-fa.service <<EOF
[Unit]
Description=Homebase dump1090-fa
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dump1090-fa --net --write-json ${RUN_DIR}/dump1090
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dump978-fa.service <<EOF
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
  systemctl enable dump1090-fa dump978-fa
}

############################################################
# 7. Web UI + nginx
############################################################
deploy_web_app() {
  log "[8/9] Web UI"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}"

  php_sock="$(detect_php_sock)"

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  server_name _;
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

############################################################
# 8. Self-test
############################################################
self_test() {
  log "[9/9] Self-test"

  echo "Hostname: $(hostname)"
  hostname -f || true

  systemctl is-active ssh && echo "✔ SSH"
  systemctl is-active nginx && echo "✔ nginx"
  command -v dump1090-fa && echo "✔ dump1090-fa"
  command -v dump978-fa && echo "✔ dump978-fa"

  echo
  echo "Homebase ready:"
  echo "  http://homebase.local"
  echo "  http://$(hostname -I | awk '{print $1}')/"
}

############################################################
# RUN
############################################################
require_root
baseline_system
git_safety
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_systemd_units
deploy_web_app
self_test