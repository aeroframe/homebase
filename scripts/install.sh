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

log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run with sudo: sudo ./scripts/install.sh"
    exit 1
  fi
}

detect_php_sock() {
  # Prefer newest PHP-FPM sock available
  local sock
  sock="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -z "${sock}" ]]; then
    echo ""
  else
    echo "${sock}"
  fi
}

write_file() {
  local path="$1"
  shift
  install -d "$(dirname "$path")"
  cat > "$path" <<'EOF'
'"$@"'
EOF
}

main_banner() {
  echo "======================================"
  echo " Homebase Beta Installer (Aeroframe)"
  echo " Raspberry Pi 4 / 64-bit OS"
  echo "======================================"
}

# ---------------------------
# Git safe.directory + perms
# ---------------------------
fix_repo_ownership() {
  log "Trust repo ownership (avoids “dubious ownership”)"
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "${REPO_ROOT}" || true

  # Ensure repo is writable by the non-root user that owns it (if applicable)
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${REPO_ROOT}" || true
  fi
}

# ---------------------------
# Packages
# ---------------------------
install_packages() {
  log "[1/9] System update"
  apt-get update -y
  apt-get upgrade -y

  log "[2/9] Install base dependencies"
  apt-get install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev

  log "[3/9] Install SoapySDR + modules"
  apt-get install -y \
    libsoapysdr-dev soapysdr-tools \
    soapysdr-module-rtlsdr soapysdr0.8-module-rtlsdr \
    soapysdr0.8-module-all soapysdr0.8-module-remote \
    soapysdr-module-hackrf soapysdr-module-airspy || true
}

# ---------------------------
# Sources
# ---------------------------
prepare_dirs() {
  log "[4/9] Prepare source directories"
  install -d "${SRC_DIR}"
  install -d "${WEB_ROOT}"
}

clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/master 2>/dev/null || true
    git -C "${dest}" reset --hard origin/main   2>/dev/null || true
  else
    log "Cloning ${name}"
    git clone "${url}" "${dest}"
  fi
}

build_dump1090() {
  log "[5/9] Build dump1090-fa"
  # FlightAware dump1090 (piaware dump1090-fa upstream)
  clone_or_update "dump1090" "https://github.com/flightaware/dump1090.git"
  pushd "${SRC_DIR}/dump1090" >/dev/null
  make -j"$(nproc)"
  install -m 755 dump1090 /usr/local/bin/dump1090-fa
  # Optional: view1090 too
  if [[ -f view1090 ]]; then install -m 755 view1090 /usr/local/bin/view1090-fa || true; fi
  popd >/dev/null
}

build_dump978() {
  log "[6/9] Build dump978-fa"
  clone_or_update "dump978" "https://github.com/flightaware/dump978.git"
  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean || true
  make -j"$(nproc)"
  install -m 755 dump978-fa /usr/local/bin/dump978-fa
  if [[ -f skyaware978 ]]; then install -m 755 skyaware978 /usr/local/bin/skyaware978 || true; fi
  popd >/dev/null
}

# ---------------------------
# Runtime dirs + helpers
# ---------------------------
setup_tmpfiles() {
  log "[7/9] Create runtime dirs (tmpfiles)"
  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF
  systemd-tmpfiles --create "${TMPFILES_CONF}"
}

install_helpers() {
  log "Install helper wrappers"

  # Wrapper waits until enough SDRs are present, then execs dump1090-fa
  cat > /usr/local/bin/homebase-wait-and-run-dump1090 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REQUIRED_DEVICES="${REQUIRED_DEVICES:-1}"
SLEEP_SEC="${SLEEP_SEC:-10}"
RUN_DIR="${RUN_DIR:-/run/homebase}"

has_devices() {
  # Use SoapySDRUtil if available; fallback to rtl_test if not
  if command -v SoapySDRUtil >/dev/null 2>&1; then
    local count
    count="$(SoapySDRUtil --find 2>/dev/null | grep -c "driver=rtlsdr" || true)"
    [[ "${count}" -ge "${REQUIRED_DEVICES}" ]]
  else
    command -v rtl_test >/dev/null 2>&1 && rtl_test -t >/dev/null 2>&1
  fi
}

echo "[homebase] dump1090 wrapper: waiting for >= ${REQUIRED_DEVICES} SDR device(s)..."
while ! has_devices; do
  sleep "${SLEEP_SEC}"
done

mkdir -p "${RUN_DIR}/dump1090"
chmod 755 "${RUN_DIR}" "${RUN_DIR}/dump1090" || true

exec /usr/local/bin/dump1090-fa ${DUMP1090_ARGS:-}
EOF
  chmod +x /usr/local/bin/homebase-wait-and-run-dump1090

  # dump978 wrapper: runs dump978-fa and caches latest JSON line into /run/homebase/dump978/latest.json
  cat > /usr/local/bin/homebase-run-dump978-cache <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REQUIRED_DEVICES="${REQUIRED_DEVICES:-2}"
SLEEP_SEC="${SLEEP_SEC:-10}"
RUN_DIR="${RUN_DIR:-/run/homebase}"
OUT_FILE="${OUT_FILE:-/run/homebase/dump978/latest.json}"

has_devices() {
  if command -v SoapySDRUtil >/dev/null 2>&1; then
    local count
    count="$(SoapySDRUtil --find 2>/dev/null | grep -c "driver=rtlsdr" || true)"
    [[ "${count}" -ge "${REQUIRED_DEVICES}" ]]
  else
    command -v rtl_test >/dev/null 2>&1 && rtl_test -t >/dev/null 2>&1
  fi
}

echo "[homebase] dump978 wrapper: waiting for >= ${REQUIRED_DEVICES} SDR device(s)..."
while ! has_devices; do
  sleep "${SLEEP_SEC}"
done

mkdir -p "${RUN_DIR}/dump978"
chmod 755 "${RUN_DIR}" "${RUN_DIR}/dump978" || true

# Run dump978-fa and cache the last JSON object line
# Note: dump978 emits one JSON object per decoded message when --json-stdout is set.
# We'll store the most recent line as valid JSON at latest.json
stdbuf -oL -eL /usr/local/bin/dump978-fa ${DUMP978_ARGS:-} --json-stdout \
| while IFS= read -r line; do
    if [[ -n "${line}" ]]; then
      printf '%s\n' "${line}" > "${OUT_FILE}.tmp" || true
      mv "${OUT_FILE}.tmp" "${OUT_FILE}" || true
      chmod 644 "${OUT_FILE}" || true
    fi
  done
EOF
  chmod +x /usr/local/bin/homebase-run-dump978-cache
}

# ---------------------------
# systemd units
# ---------------------------
install_systemd_units() {
  log "Install systemd services"

  cat > /etc/default/dump1090-fa <<'EOF'
# Homebase dump1090-fa defaults
#
# Multi-SDR setup:
# - If using RTL-SDR direct: use --device-index 0
# - If using Soapy: use --device-type soapy --device "driver=rtlsdr,serial=XXXX"
#
# JSON is written to /run/homebase/dump1090/aircraft.json etc.

DUMP1090_ARGS="--device-type rtlsdr --device-index 0 \
--net --net-http-port 30047 \
--write-json /run/homebase/dump1090 --write-json-every 1"
EOF

  cat > /etc/default/dump978-fa <<'EOF'
# Homebase dump978-fa defaults
#
# Multi-SDR setup:
# Use the *second* dongle for UAT (index 1 or a specific serial).
# Examples:
#   DUMP978_ARGS="--sdr driver=rtlsdr,serial=00000002"
#   DUMP978_ARGS="--sdr driver=rtlsdr,index=1"
#
# The wrapper always adds --json-stdout to cache latest JSON to:
#   /run/homebase/dump978/latest.json

DUMP978_ARGS="--sdr driver=rtlsdr,index=1"
EOF

  cat > /etc/systemd/system/dump1090-fa.service <<'EOF'
[Unit]
Description=Homebase dump1090-fa (1090 MHz ADS-B)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/dump1090-fa
Environment=REQUIRED_DEVICES=1
Environment=RUN_DIR=/run/homebase
Restart=always
RestartSec=3
ExecStart=/usr/local/bin/homebase-wait-and-run-dump1090
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dump978-fa.service <<'EOF'
[Unit]
Description=Homebase dump978-fa (978 MHz UAT) + JSON cache
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/dump978-fa
Environment=REQUIRED_DEVICES=2
Environment=RUN_DIR=/run/homebase
Environment=OUT_FILE=/run/homebase/dump978/latest.json
Restart=always
RestartSec=3
ExecStart=/usr/local/bin/homebase-run-dump978-cache
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dump1090-fa.service dump978-fa.service
  systemctl restart dump1090-fa.service dump978-fa.service || true
}

# ---------------------------
# Web app (nginx + PHP)
# ---------------------------
deploy_web_app() {
  log "Deploy /homebase-app to nginx web root"

  # Copy repo web app
  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"

  # Add JSON endpoints (in case you want stable paths)
  install -d "${WEB_ROOT}/feeds"

  cat > "${WEB_ROOT}/feeds/dump1090-aircraft.php" <<'EOF'
<?php
header('Content-Type: application/json');
$path = '/run/homebase/dump1090/aircraft.json';
if (!file_exists($path)) { http_response_code(404); echo json_encode(['error'=>'dump1090 aircraft.json not found']); exit; }
readfile($path);
EOF

  cat > "${WEB_ROOT}/feeds/dump978-latest.php" <<'EOF'
<?php
header('Content-Type: application/json');
$path = '/run/homebase/dump978/latest.json';
if (!file_exists($path)) { http_response_code(404); echo json_encode(['error'=>'dump978 latest.json not found']); exit; }
readfile($path);
EOF

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

  chmod -R 755 "${WEB_ROOT}" || true
  find "${WEB_ROOT}" -type f -name "*.php" -exec chmod 644 {} \; || true
}

install_nginx_site() {
  log "Install nginx site for Homebase"

  local php_sock
  php_sock="$(detect_php_sock)"
  if [[ -z "${php_sock}" ]]; then
    echo "ERROR: Could not find PHP-FPM socket in /run/php/. Is php-fpm installed/running?"
    exit 1
  fi

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  server_name _;
  root ${WEB_ROOT};
  index index.php index.html;

  # Basic security headers
  add_header X-Content-Type-Options nosniff always;
  add_header X-Frame-Options SAMEORIGIN always;

  # Allow fetch() from other devices on LAN
  add_header Access-Control-Allow-Origin * always;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  # Serve runtime JSON directory (optional)
  location /feeds/ {
    try_files \$uri \$uri/ =404;
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

verify() {
  log "[8/9] Verify installs"
  /usr/local/bin/dump1090-fa --help >/dev/null 2>&1 && echo "✔ dump1090-fa installed"
  /usr/local/bin/dump978-fa --help  >/dev/null 2>&1 && echo "✔ dump978-fa installed"
  command -v SoapySDRUtil >/dev/null 2>&1 && echo "✔ SoapySDR installed"

  log "[9/9] Done"
  echo "Open: http://<PI_IP>/"
  echo "dump1090 JSON: http://<PI_IP>/feeds/dump1090-aircraft.php"
  echo "dump978 JSON:  http://<PI_IP>/feeds/dump978-latest.php"
  echo "combined JSON: http://<PI_IP>/feeds/combined.php"
}

# ---------------------------
# Run
# ---------------------------
require_root
main_banner
fix_repo_ownership
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_helpers
install_systemd_units
deploy_web_app
install_nginx_site
verify