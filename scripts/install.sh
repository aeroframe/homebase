#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
# Plug-n-play: Ethernet stays mgmt, Wi-Fi runs hotspot
############################################################

### CONSTANTS
TARGET_HOSTNAME="homebase"

# Hotspot defaults (change if you want)
AP_SSID="Homebase"
AP_PASS="homebase123"          # WPA2 password (8+ chars)
AP_IP="10.42.0.1"
AP_CIDR="10.42.0.1/24"
DHCP_RANGE_START="10.42.0.10"
DHCP_RANGE_END="10.42.0.100"
DHCP_LEASE="12h"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

### HELPERS
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

wait_for_apt_lock() {
  # Avoid "Could not get lock /var/lib/dpkg/lock-frontend"
  local waited=0
  local max_wait=300
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if (( waited >= max_wait )); then
      echo "ERROR: apt/dpkg lock held too long. Try rebooting and rerun install.sh"
      exit 1
    fi
    (( waited += 5 ))
    sleep 5
  done
}

apt_install() {
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_update() {
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get update -y
}

apt_upgrade() {
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

############################################################
# 0. CRITICAL BASELINE (SSH + HOSTNAME + mDNS)
############################################################
baseline_system() {
  log "[0/10] Baseline system (SSH + hostname + mDNS)"

  apt_update
  apt_install openssh-server avahi-daemon avahi-utils

  systemctl enable ssh
  systemctl restart ssh

  # Ensure ssh listens everywhere (avoid accidental ListenAddress restrictions)
  if ! grep -q "^ListenAddress 0.0.0.0" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i '/^ListenAddress/d' /etc/ssh/sshd_config || true
    cat >> /etc/ssh/sshd_config <<'EOF'

# Homebase: ensure SSH listens on all interfaces
ListenAddress 0.0.0.0
ListenAddress ::
EOF
    systemctl restart ssh
  fi

  local current_host
  current_host="$(hostname)"

  if [[ "${current_host}" != "${TARGET_HOSTNAME}" ]]; then
    log "Setting hostname → ${TARGET_HOSTNAME}"
    hostnamectl set-hostname "${TARGET_HOSTNAME}"
  fi

  # Fix /etc/hosts (prevents sudo "unable to resolve host")
  if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi

  systemctl restart systemd-hostnamed
  systemctl enable avahi-daemon
  systemctl restart avahi-daemon
}

############################################################
# 1. GIT SAFETY
############################################################
fix_git_safety() {
  log "[1/10] Git safe.directory"
  apt_install git
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "${REPO_ROOT}" || true
}

############################################################
# 2. SYSTEM PACKAGES
############################################################
install_packages() {
  log "[2/10] Install packages"

  apt_update
  apt_upgrade

  apt_install \
    curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all

  # Unmask hostapd if distro masked it
  systemctl unmask hostapd >/dev/null 2>&1 || true
}

############################################################
# 3. DIRECTORIES
############################################################
prepare_dirs() {
  log "[3/10] Create directories"
  install -d "${SRC_DIR}" "${WEB_ROOT}" "${RUN_DIR}"
}

############################################################
# 4. BUILD SDR SOFTWARE
############################################################
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/main 2>/dev/null || \
    git -C "${dest}" reset --hard origin/master
  else
    log "Cloning ${name}"
    git clone "${url}" "${dest}"
  fi
}

build_dump1090() {
  log "[4/10] Build dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  pushd "${SRC_DIR}/dump1090" >/dev/null
  make -j"$(nproc)"
  install -m 755 dump1090 /usr/local/bin/dump1090-fa
  popd >/dev/null
}

build_dump978() {
  log "[5/10] Build dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean || true
  make -j"$(nproc)"
  install -m 755 dump978-fa /usr/local/bin/dump978-fa
  popd >/dev/null
}

############################################################
# 5. RUNTIME DIRECTORIES
############################################################
setup_tmpfiles() {
  log "[6/10] Runtime dirs"
  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF
  systemd-tmpfiles --create
}

############################################################
# 6. HOTSPOT CONFIG (wlan0 AP) - DO NOT TOUCH eth0
############################################################
configure_hotspot() {
  log "[7/10] Configure Wi-Fi hotspot (wlan0) without breaking Ethernet"

  # Detect wlan0 presence
  if ! ip link show wlan0 >/dev/null 2>&1; then
    log "WARNING: wlan0 not found. Skipping hotspot configuration."
    return 0
  fi

  # hostapd config must be in /etc/hostapd/hostapd.conf for ConditionFileNotEmpty
  install -d /etc/hostapd
  cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=7
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  # Tell default hostapd service where the config lives
  if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd || true
  else
    cat > /etc/default/hostapd <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
  fi

  # dnsmasq config scoped only to wlan0
  install -d /etc/dnsmasq.d
  cat > /etc/dnsmasq.d/homebase.conf <<EOF
interface=wlan0
bind-interfaces
domain-needed
bogus-priv
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}

# Make homebase.local resolve while connected to hotspot
address=/homebase.local/${AP_IP}
EOF

  # Systemd service to apply static IP on wlan0 and start AP services
  cat > /etc/systemd/system/homebase-hotspot.service <<'EOF'
[Unit]
Description=Homebase Hotspot (wlan0 AP) - leaves Ethernet untouched
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  set -e; \
  ip link set wlan0 down || true; \
  ip addr flush dev wlan0 || true; \
  ip addr add 10.42.0.1/24 dev wlan0; \
  ip link set wlan0 up; \
  systemctl unmask hostapd >/dev/null 2>&1 || true; \
  systemctl restart dnsmasq; \
  systemctl restart hostapd; \
'

ExecStop=/bin/bash -c '\
  set -e; \
  systemctl stop hostapd || true; \
  systemctl stop dnsmasq || true; \
  ip link set wlan0 down || true; \
  ip addr flush dev wlan0 || true; \
  ip link set wlan0 up || true; \
'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable homebase-hotspot.service

  # Make sure hostapd isn't "skipped" due to missing config
  systemctl enable hostapd dnsmasq

  # Start hotspot now (Ethernet remains as-is)
  systemctl restart homebase-hotspot.service || true
}

############################################################
# 7. SYSTEMD SERVICES (dump1090/dump978)
############################################################
install_systemd_units() {
  log "[8/10] systemd services"

  cat > /etc/systemd/system/dump1090-fa.service <<EOF
[Unit]
Description=Homebase dump1090-fa
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dump1090-fa --net --write-json ${RUN_DIR}/dump1090 --write-json-every 1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dump978-fa.service <<EOF
[Unit]
Description=Homebase dump978-fa
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dump1090-fa dump978-fa
  systemctl restart dump1090-fa dump978-fa || true
}

############################################################
# 8. WEB UI + NGINX
############################################################
deploy_web_app() {
  log "[9/10] Web UI + nginx"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}" || true

  local php_sock
  php_sock="$(detect_php_sock)"
  if [[ -z "${php_sock}" ]]; then
    echo "ERROR: PHP-FPM socket not found. Is php-fpm installed?"
    exit 1
  fi

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root ${WEB_ROOT};
  index index.php index.html;

  # Allow LAN fetches
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

############################################################
# 9. SELF TEST
############################################################
self_test() {
  log "[10/10] Self-test"

  echo "Hostname: $(hostname)"
  hostname -f || true
  echo

  systemctl is-active ssh >/dev/null && echo "✔ SSH running" || echo "✖ SSH not running"
  systemctl is-active avahi-daemon >/dev/null && echo "✔ mDNS (avahi) running" || echo "✖ avahi not running"
  systemctl is-active nginx >/dev/null && echo "✔ nginx running" || echo "✖ nginx not running"

  command -v dump1090-fa >/dev/null && echo "✔ dump1090-fa installed" || echo "✖ dump1090-fa missing"
  command -v dump978-fa >/dev/null && echo "✔ dump978-fa installed" || echo "✖ dump978-fa missing"

  if ip link show wlan0 >/dev/null 2>&1; then
    ip addr show wlan0 | grep -q "${AP_IP}" && echo "✔ wlan0 AP IP set (${AP_IP})" || echo "✖ wlan0 AP IP not set"
    systemctl is-enabled homebase-hotspot >/dev/null 2>&1 && echo "✔ hotspot enabled on boot" || echo "✖ hotspot not enabled"
    systemctl is-active hostapd >/dev/null 2>&1 && echo "✔ hostapd active" || echo "✖ hostapd inactive"
    systemctl is-active dnsmasq >/dev/null 2>&1 && echo "✔ dnsmasq active" || echo "✖ dnsmasq inactive"
  else
    echo "ℹ wlan0 not present; hotspot skipped"
  fi

  echo
  echo "Homebase UI:"
  echo "  http://homebase.local"
  echo "  http://${AP_IP} (when connected to hotspot)"
  echo
  echo "Hotspot:"
  echo "  SSID: ${AP_SSID}"
  echo "  PASS: ${AP_PASS}"
}

############################################################
# RUN
############################################################
require_root
baseline_system
fix_git_safety
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
configure_hotspot
install_systemd_units
deploy_web_app
self_test