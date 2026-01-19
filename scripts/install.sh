#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# Goals:
# - Plug-n-play install
# - NEVER switch networking live during install (prevents SSH drop)
# - Hotspot mode is selected ONLY at BOOT using a flag file:
#     /boot/firmware/homebase-hotspot   (Pi OS)
#     /boot/homebase-hotspot            (some distros)
#
# What this script does:
# - Baseline: SSH + Avahi/mDNS + hostname + locale fix
# - Installs packages (one apt phase, robust lock handling)
# - Builds dump1090 + dump978 (non-blocking: warns + continues on failure)
# - Installs runtime dirs via tmpfiles
# - Installs hotspot configs (hostapd + dnsmasq) but does NOT start hotspot now
# - Installs systemd units:
#     - dump1090-fa.service
#     - dump978-fa.service (with latest.json cache)
#     - homebase-normal.service
#     - homebase-hotspot.service
#     - homebase-net-select.service (boot-time selector)
# - Deploys web UI + nginx site
# - Runs a post-install self-test
############################################################

TARGET_HOSTNAME="homebase"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

# Boot partition path differs between distros
BOOT_FLAG=""
if [[ -d /boot/firmware ]]; then
  BOOT_FLAG="/boot/firmware/homebase-hotspot"
elif [[ -d /boot ]]; then
  BOOT_FLAG="/boot/homebase-hotspot"
else
  BOOT_FLAG="/boot/firmware/homebase-hotspot"
fi

# Log file
LOG_FILE="/var/log/homebase-install.log"

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

main_banner() {
  echo "======================================"
  echo " Homebase Installer (Aeroframe)"
  echo " Raspberry Pi OS / Debian (Trixie)"
  echo "======================================"
  echo "Logging to: ${LOG_FILE}"
}

# Stop/mask background apt jobs that can steal dpkg lock mid-install
disable_apt_timers() {
  log "Disabling background apt timers/services (prevents dpkg lock conflicts)"
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}

wait_for_apt() {
  log "Waiting for apt/dpkg locks (if any)..."
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
      echo "If this is a fresh image, try rebooting once and re-running install."
      echo "You can also try:"
      echo "  sudo systemctl stop unattended-upgrades || true"
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
  # Different distros use different unit names
  # - Debian meta: php-fpm (may or may not exist)
  # - Versioned: php8.2-fpm / php8.3-fpm / php8.4-fpm
  log "Ensuring PHP-FPM is enabled and running"

  if systemctl list-unit-files | grep -q '^php-fpm\.service'; then
    systemctl enable --now php-fpm >/dev/null 2>&1 || true
  else
    local svc
    svc="$(systemctl list-unit-files | awk '{print $1}' | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' | sort -V | tail -n 1 || true)"
    if [[ -n "${svc}" ]]; then
      systemctl enable --now "${svc}" >/dev/null 2>&1 || true
    fi
  fi

  # Give it a second to create the socket
  sleep 2
}

############################################################
# 0. Baseline system (SAFE)
############################################################
baseline_system() {
  log "[0/11] Baseline (SSH + hostname + mDNS + locale fix)"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  # SSH (critical)
  systemctl enable --now ssh >/dev/null 2>&1 || true

  # Locale warnings fix (common on fresh images)
  if ! locale -a | grep -qiE '^en_GB\.utf8$'; then
    log "Generating locale en_GB.UTF-8 (removes perl/locale warnings)"
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen >/dev/null 2>&1 || true
  fi

  # Hostname
  local current_host
  current_host="$(hostname)"
  if [[ "${current_host}" != "${TARGET_HOSTNAME}" ]]; then
    log "Setting hostname → ${TARGET_HOSTNAME}"
    hostnamectl set-hostname "${TARGET_HOSTNAME}"
  fi

  # /etc/hosts mapping (prevents: sudo: unable to resolve host)
  if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi

  systemctl restart systemd-hostnamed >/dev/null 2>&1 || true
  systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

############################################################
# 1. Git safety
############################################################
git_safety() {
  log "[1/11] Git safe.directory"
  git config --global --add safe.directory /opt/homebase >/dev/null 2>&1 || true
  git config --global --add safe.directory "${REPO_ROOT}" >/dev/null 2>&1 || true
}

############################################################
# 2. Packages (single phase)
############################################################
install_packages() {
  log "[2/11] Installing packages"

  apt_run update -y
  apt_run upgrade -y

  apt_run install -y \
    git curl ca-certificates rsync \
    nginx php-fpm \
    python3 python3-pip \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all

  # hostapd is sometimes masked by default on Pi OS until config exists
  systemctl unmask hostapd >/dev/null 2>&1 || true
}

############################################################
# 3. Directories
############################################################
prepare_dirs() {
  log "[3/11] Creating directories"
  install -d "${SRC_DIR}" "${WEB_ROOT}" "${RUN_DIR}"
}

############################################################
# 4. SDR builds (non-blocking)
############################################################
clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${SRC_DIR}/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune >/dev/null
    git -C "${dest}" reset --hard origin/main >/dev/null 2>&1 || \
    git -C "${dest}" reset --hard origin/master >/dev/null 2>&1 || true
  else
    log "Cloning ${name}"
    git clone "${url}" "${dest}"
  fi
}

build_dump1090() {
  log "[4/11] Build dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git

  pushd "${SRC_DIR}/dump1090" >/dev/null
  if ! make -j"$(nproc)"; then
    echo "WARN: dump1090 build failed. Continuing install."
    popd >/dev/null
    return 0
  fi

  if [[ -f dump1090 ]]; then
    install -m 755 dump1090 /usr/local/bin/dump1090-fa || true
  else
    echo "WARN: dump1090 binary not found after build. Continuing."
  fi
  popd >/dev/null
}

build_dump978() {
  log "[5/11] Build dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git

  pushd "${SRC_DIR}/dump978" >/dev/null
  make clean >/dev/null 2>&1 || true
  if ! make -j"$(nproc)"; then
    echo "WARN: dump978 build failed. Continuing install."
    popd >/dev/null
    return 0
  fi

  if [[ -f dump978-fa ]]; then
    install -m 755 dump978-fa /usr/local/bin/dump978-fa || true
  else
    echo "WARN: dump978-fa binary not found after build. Continuing."
  fi
  popd >/dev/null
}

############################################################
# 5. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[6/11] Runtime directories"
  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF
  systemd-tmpfiles --create >/dev/null 2>&1 || true
}

############################################################
# 6. Hotspot configs (installed, not switched live)
############################################################
install_hotspot_configs() {
  log "[7/11] Install hotspot configs (hostapd + dnsmasq)"

  install -d /etc/hostapd

  # IMPORTANT:
  # - Choose a password you’ll remember (8+ chars).
  # - You can rebrand later.
  cat > /etc/hostapd/hostapd.conf <<'EOF'
interface=wlan0
driver=nl80211
ssid=Homebase
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=homebase1234
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211n=1
EOF

  # dnsmasq DHCP for hotspot
  cat > /etc/dnsmasq.d/homebase.conf <<'EOF'
interface=wlan0
bind-interfaces
dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,24h
domain=local
address=/homebase.local/10.42.0.1
EOF

  # Ensure dnsmasq loads /etc/dnsmasq.d configs
  if ! grep -q "^conf-dir=/etc/dnsmasq.d" /etc/dnsmasq.conf 2>/dev/null; then
    echo "conf-dir=/etc/dnsmasq.d,*.conf" >> /etc/dnsmasq.conf
  fi

  # Ensure hostapd knows where its config is
  cat > /etc/default/hostapd <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

  # Enable, but DO NOT start hotspot services here
  systemctl unmask hostapd >/dev/null 2>&1 || true
  systemctl enable hostapd dnsmasq >/dev/null 2>&1 || true
}

############################################################
# 7. systemd units
############################################################
install_systemd_units() {
  log "[8/11] Install systemd services"

  # dump1090-fa
  cat > /etc/systemd/system/dump1090-fa.service <<EOF
[Unit]
Description=Homebase dump1090-fa
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=2
ExecStart=/usr/local/bin/dump1090-fa --net --write-json ${RUN_DIR}/dump1090 --write-json-every 1

[Install]
WantedBy=multi-user.target
EOF

  # dump978 cache wrapper -> latest.json
  cat > /usr/local/bin/homebase-dump978-cache <<EOF
#!/usr/bin/env bash
set -euo pipefail
install -d ${RUN_DIR}/dump978
OUT="${RUN_DIR}/dump978/latest.json"
stdbuf -oL -eL /usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout \\
| while IFS= read -r line; do
    [[ -z "\${line}" ]] && continue
    printf '%s\n' "\${line}" > "\${OUT}.tmp" || true
    mv "\${OUT}.tmp" "\${OUT}" || true
    chmod 644 "\${OUT}" || true
  done
EOF
  chmod +x /usr/local/bin/homebase-dump978-cache

  cat > /etc/systemd/system/dump978-fa.service <<EOF
[Unit]
Description=Homebase dump978-fa (with JSON cache)
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=2
ExecStart=/usr/local/bin/homebase-dump978-cache

[Install]
WantedBy=multi-user.target
EOF

  # Normal mode (do NOT assume dhcpcd exists)
  cat > /etc/systemd/system/homebase-normal.service <<'EOF'
[Unit]
Description=Homebase Normal Network Mode
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  systemctl stop hostapd dnsmasq 2>/dev/null || true; \
  ip addr flush dev wlan0 2>/dev/null || true; \
  ip link set wlan0 up 2>/dev/null || true; \
  true'
EOF

  # Hotspot mode (static IP + start dnsmasq/hostapd)
  cat > /etc/systemd/system/homebase-hotspot.service <<'EOF'
[Unit]
Description=Homebase Hotspot Mode
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ip link set wlan0 down 2>/dev/null || true; \
  ip addr flush dev wlan0 2>/dev/null || true; \
  ip addr add 10.42.0.1/24 dev wlan0; \
  ip link set wlan0 up; \
  systemctl restart dnsmasq; \
  systemctl restart hostapd'
EOF

  # Boot-time selector: chooses hotspot vs normal based on BOOT_FLAG
  cat > /usr/local/sbin/homebase-net-select <<EOF
#!/usr/bin/env bash
set -euo pipefail
FLAG="${BOOT_FLAG}"

if [[ -f "\${FLAG}" ]]; then
  echo "[homebase] Boot flag present -> HOTSPOT mode"
  systemctl start homebase-hotspot.service
else
  echo "[homebase] Boot flag absent -> NORMAL mode"
  systemctl start homebase-normal.service
fi
EOF
  chmod +x /usr/local/sbin/homebase-net-select

  cat > /etc/systemd/system/homebase-net-select.service <<'EOF'
[Unit]
Description=Homebase Network Mode Selector (boot-time)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homebase-net-select

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload

  # Enable SDR services (start later; no network switching here)
  systemctl enable dump1090-fa dump978-fa >/dev/null 2>&1 || true
  systemctl enable homebase-net-select.service >/dev/null 2>&1 || true
}

############################################################
# 8. Web UI + nginx
############################################################
deploy_web_app() {
  log "[9/11] Deploy web UI + nginx"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}"

  ensure_php_fpm_running

  local php_sock
  php_sock="$(detect_php_sock)"
  if [[ -z "${php_sock}" ]]; then
    echo "WARN: PHP-FPM socket not found yet. Attempting to continue."
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
    $( [[ -n "${php_sock}" ]] && echo "fastcgi_pass unix:${php_sock};" || echo "# fastcgi_pass will be configured once php-fpm socket exists" )
  }
}
EOF

  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1 || true

  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

############################################################
# 9. Start app services (safe)
############################################################
start_services() {
  log "[10/11] Starting services (safe)"
  systemctl restart dump1090-fa >/dev/null 2>&1 || true
  systemctl restart dump978-fa >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
}

############################################################
# 10. Self-test
############################################################
self_test() {
  log "[11/11] Self-test"

  echo "Hostname: $(hostname)"
  hostname -f || true

  systemctl is-active ssh >/dev/null && echo "✔ SSH running" || echo "✖ SSH not running"
  systemctl is-active avahi-daemon >/dev/null && echo "✔ avahi running" || echo "✖ avahi not running"
  systemctl is-active nginx >/dev/null && echo "✔ nginx running" || echo "✖ nginx not running"

  if command -v dump1090-fa >/dev/null 2>&1; then
    echo "✔ dump1090-fa installed"
  else
    echo "✖ dump1090-fa missing (build likely failed)"
  fi

  if command -v dump978-fa >/dev/null 2>&1; then
    echo "✔ dump978-fa installed"
  else
    echo "✖ dump978-fa missing (build likely failed)"
  fi

  systemctl is-enabled dump1090-fa >/dev/null 2>&1 && echo "✔ dump1090 enabled" || echo "✖ dump1090 not enabled"
  systemctl is-enabled dump978-fa >/dev/null 2>&1 && echo "✔ dump978 enabled" || echo "✖ dump978 not enabled"

  local ip
  ip="$(hostname -I | awk '{print $1}')"

  echo
  echo "Homebase UI:"
  echo "  http://homebase.local/"
  echo "  http://${ip}/"
  echo
  echo "Hotspot boot selector:"
  echo "  Boot flag path: ${BOOT_FLAG}"
  echo
  echo "Enable hotspot for NEXT boot:"
  echo "  sudo touch ${BOOT_FLAG} && sudo reboot"
  echo
  echo "Return to normal mode on NEXT boot:"
  echo "  sudo rm -f ${BOOT_FLAG} && sudo reboot"
  echo
  echo "IMPORTANT:"
  echo "  Do NOT start hotspot while SSH'd in:"
  echo "    systemctl start homebase-hotspot"
  echo "  Always switch modes by creating/removing the boot flag, then rebooting."
}

############################################################
# Run (with logging)
############################################################
require_root
main_banner

# Tee all output to log file
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

disable_apt_timers
baseline_system
git_safety
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_hotspot_configs
install_systemd_units
deploy_web_app
start_services
self_test