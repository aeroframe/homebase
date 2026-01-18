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

# Homebase identity (mDNS)
HOMEBASE_HOSTNAME="${HOMEBASE_HOSTNAME:-homebase}"

log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

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
  echo " Raspberry Pi / Debian (Trixie) / 64-bit"
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
# Critical: SSH must exist
# ---------------------------
ensure_ssh() {
  log "Ensure SSH access (critical)"
  apt-get update -y
  apt-get install -y openssh-server

  systemctl enable ssh
  systemctl restart ssh

  if ! systemctl is-active --quiet ssh; then
    echo "FATAL: SSH is not running. Aborting."
    exit 1
  fi

  # Optional hardening: keep it alive
  mkdir -p /etc/systemd/system/ssh.service.d
  cat > /etc/systemd/system/ssh.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF
  systemctl daemon-reload
  systemctl restart ssh
}

# ---------------------------
# Hostname + mDNS
# ---------------------------
configure_hostname_mdns() {
  log "Configure hostname + mDNS (${HOMEBASE_HOSTNAME}.local)"
  apt-get install -y avahi-daemon avahi-utils

  # Set hostname
  echo "${HOMEBASE_HOSTNAME}" > /etc/hostname
  hostnamectl set-hostname "${HOMEBASE_HOSTNAME}" || true

  systemctl enable avahi-daemon
  systemctl restart avahi-daemon
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
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev

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
# Git helper
# ---------------------------
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    ( git -C "${dest}" reset --hard origin/main ) 2>/dev/null || \
    ( git -C "${dest}" reset --hard origin/master )
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
  systemd-tmpfiles --create "${TMPFILES_CONF}"
}

# ---------------------------
# Helpers (dump978 cache writer)
# ---------------------------
install_helpers() {
  log "Install helper scripts"

  # dump978 wrapper: write most recent JSON object to /run/homebase/dump978/latest.json
  cat > /usr/local/bin/homebase-dump978-cache <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${RUN_DIR:-/run/homebase}"
OUT="${OUT_FILE:-/run/homebase/dump978/latest.json}"

mkdir -p "${RUN_DIR}/dump978"
chmod 755 "${RUN_DIR}" "${RUN_DIR}/dump978" || true

# Exec dump978, capture line-buffered output
stdbuf -oL -eL /usr/local/bin/dump978-fa ${DUMP978_ARGS:-} --json-stdout \
| while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf '%s\n' "${line}" > "${OUT}.tmp" || true
    mv "${OUT}.tmp" "${OUT}" || true
    chmod 644 "${OUT}" || true
  done
EOF
  chmod +x /usr/local/bin/homebase-dump978-cache
}

# ---------------------------
# Network configs (Option A support)
# ---------------------------
install_network_configs() {
  log "Install network configs (hostapd/dnsmasq/dhcpcd)"

  # These should exist in your repo:
  #   network/hostapd.conf
  #   network/dnsmasq-homebase.conf
  #   network/dhcpcd-homebase.conf
  #
  # We deploy them to standard locations.

  if [[ -f "${REPO_ROOT}/network/hostapd.conf" ]]; then
    install -d /etc/hostapd
    install -m 644 "${REPO_ROOT}/network/hostapd.conf" /etc/hostapd/hostapd.conf

    # Ensure hostapd uses this config
    if [[ -f /etc/default/hostapd ]]; then
      sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd || true
    else
      cat > /etc/default/hostapd <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
    fi
  fi

  if [[ -f "${REPO_ROOT}/network/dnsmasq-homebase.conf" ]]; then
    install -d /etc/dnsmasq.d
    install -m 644 "${REPO_ROOT}/network/dnsmasq-homebase.conf" /etc/dnsmasq.d/homebase.conf
  fi

  if [[ -f "${REPO_ROOT}/network/dhcpcd-homebase.conf" ]]; then
    install -d /etc/dhcpcd.conf.d
    install -m 644 "${REPO_ROOT}/network/dhcpcd-homebase.conf" /etc/dhcpcd.conf.d/homebase.conf
  fi
}

# ---------------------------
# Systemd services
# ---------------------------
install_systemd_units() {
  log "Installing systemd services"

  # Homebase mode units from repo
  if compgen -G "${REPO_ROOT}/systemd/homebase-*.service" > /dev/null; then
    install -m 644 "${REPO_ROOT}/systemd/homebase-"*.service /etc/systemd/system/
  fi

  # dump1090 service
  cat > /etc/systemd/system/dump1090-fa.service <<'EOF'
[Unit]
Description=Homebase dump1090-fa (1090 MHz)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=3
ExecStart=/usr/local/bin/dump1090-fa --net --write-json /run/homebase/dump1090 --write-json-every 1

[Install]
WantedBy=multi-user.target
EOF

  # dump978 service (uses cache wrapper)
  cat > /etc/systemd/system/dump978-fa.service <<'EOF'
[Unit]
Description=Homebase dump978-fa (978 MHz) + cache
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=3
Environment=RUN_DIR=/run/homebase
Environment=OUT_FILE=/run/homebase/dump978/latest.json
# Default multi-SDR: second dongle is index=1
Environment=DUMP978_ARGS=--sdr driver=rtlsdr,index=1
ExecStart=/usr/local/bin/homebase-dump978-cache

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload

  # Enable core services
  systemctl enable dump1090-fa dump978-fa || true
  systemctl restart dump1090-fa dump978-fa || true

  # Enable boot mode if present
  if systemctl list-unit-files | grep -q '^homebase-boot\.service'; then
    systemctl enable homebase-boot || true
  fi
}

# ---------------------------
# Web UI + feeds
# ---------------------------
deploy_web_app() {
  log "Deploying web UI"
  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"

  install -d "${WEB_ROOT}/feeds"

  # dump1090 aircraft.json passthrough
  cat > "${WEB_ROOT}/feeds/dump1090-aircraft.php" <<'EOF'
<?php
header('Content-Type: application/json');
$path = '/run/homebase/dump1090/aircraft.json';
if (!file_exists($path)) { http_response_code(404); echo json_encode(['error'=>'dump1090 aircraft.json not found']); exit; }
readfile($path);
EOF

  # dump978 latest.json passthrough
  cat > "${WEB_ROOT}/feeds/dump978-latest.php" <<'EOF'
<?php
header('Content-Type: application/json');
$path = '/run/homebase/dump978/latest.json';
if (!file_exists($path)) { http_response_code(404); echo json_encode(['error'=>'dump978 latest.json not found']); exit; }
readfile($path);
EOF

  # combined
  cat > "${WEB_ROOT}/feeds/combined.php" <<'EOF'
<?php
header('Content-Type: application/json');

$adsb = '/run/homebase/dump1090/aircraft.json';
$uat  = '/run/homebase/dump978/latest.json';

$out = [
  'generated_at' => gmdate('c'),
  'dump1090' => file_exists($adsb) ? json_decode(file_get_contents($adsb), true) : null,
  'dump978'  => file_exists($uat)  ? json_decode(file_get_contents($uat), true)  : null,
];

echo json_encode($out);
EOF

  chown -R www-data:www-data "${WEB_ROOT}" || true
  chmod -R 755 "${WEB_ROOT}" || true
  find "${WEB_ROOT}" -type f -name "*.php" -exec chmod 644 {} \; || true
}

install_nginx_site() {
  log "Configuring nginx"

  local php_sock
  php_sock="$(detect_php_sock)"
  if [[ -z "${php_sock}" ]]; then
    echo "ERROR: Could not find PHP-FPM socket in /run/php/. Is php-fpm running?"
    exit 1
  fi

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  server_name _;
  root ${WEB_ROOT};
  index index.php index.html;

  add_header Access-Control-Allow-Origin * always;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
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
# Self-test (hard checks)
# ---------------------------
self_test() {
  log "[9/9] Self-test"

  # SSH
  systemctl is-active --quiet ssh && echo "✔ ssh active" || (echo "✖ ssh inactive" && exit 1)

  # mDNS
  systemctl is-active --quiet avahi-daemon && echo "✔ avahi active" || echo "✖ avahi inactive"

  # Web
  systemctl is-active --quiet nginx && echo "✔ nginx active" || (echo "✖ nginx inactive" && exit 1)

  # Binaries
  command -v dump1090-fa >/dev/null && echo "✔ dump1090-fa installed" || (echo "✖ dump1090-fa missing" && exit 1)
  command -v dump978-fa  >/dev/null && echo "✔ dump978-fa installed"  || (echo "✖ dump978-fa missing" && exit 1)

  # Units enabled
  systemctl is-enabled --quiet dump1090-fa && echo "✔ dump1090 enabled" || echo "✖ dump1090 not enabled"
  systemctl is-enabled --quiet dump978-fa  && echo "✔ dump978 enabled"  || echo "✖ dump978 not enabled"

  echo
  echo "Homebase ready:"
  echo "  UI:        http://${HOMEBASE_HOSTNAME}.local/"
  echo "  Combined:  http://${HOMEBASE_HOSTNAME}.local/feeds/combined.php"
  echo "  dump1090:   http://${HOMEBASE_HOSTNAME}.local/feeds/dump1090-aircraft.php"
  echo "  dump978:    http://${HOMEBASE_HOSTNAME}.local/feeds/dump978-latest.php"
}

# ---------------------------
# Run
# ---------------------------
require_root
main_banner
fix_repo_ownership
ensure_ssh
configure_hostname_mdns
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_helpers
install_network_configs
install_systemd_units
deploy_web_app
install_nginx_site
self_test