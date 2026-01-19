#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# Key design:
# - NEVER switch networking live during install (prevents SSH drop).
# - Hotspot mode is selected at BOOT using a flag file:
#     /boot/firmware/homebase-hotspot
#   If present -> hotspot mode
#   If absent  -> normal mode
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

# More robust apt lock wait
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
    if [[ $waited -ge 120 ]]; then
      echo "ERROR: apt/dpkg lock still held after ${waited}s. Another install may be running."
      echo "Try: sudo systemctl stop unattended-upgrades || true"
      exit 1
    fi
  done
}

apt_run() {
  # Usage: apt_run install -y pkga pkgb...
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n 1 || true
}

############################################################
# 0. Baseline system (SAFE)
############################################################
baseline_system() {
  log "[0/11] Baseline (SSH + hostname + mDNS + locale fix)"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh || true

  # Fix locale warnings (common on fresh images)
  if ! locale -a | grep -qiE '^en_GB\.utf8$'; then
    log "Generating locale en_GB.UTF-8 (removes perl/locale warnings)"
    sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen || true
    locale-gen || true
  fi

  local current_host
  current_host="$(hostname)"
  if [[ "${current_host}" != "${TARGET_HOSTNAME}" ]]; then
    log "Setting hostname → ${TARGET_HOSTNAME}"
    hostnamectl set-hostname "${TARGET_HOSTNAME}"
  fi

  # Ensure /etc/hosts contains 127.0.1.1 mapping (prevents sudo: unable to resolve host)
  if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts
  fi

  systemctl restart systemd-hostnamed || true
  systemctl restart avahi-daemon || true
}

############################################################
# 1. Git safety
############################################################
git_safety() {
  log "[1/11] Git safe.directory"
  git config --global --add safe.directory /opt/homebase || true
  git config --global --add safe.directory "${REPO_ROOT}" || true
}

############################################################
# 2. Packages
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
  systemctl unmask hostapd 2>/dev/null || true
}

############################################################
# 3. Directories
############################################################
prepare_dirs() {
  log "[3/11] Creating directories"
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
    log "Updating ${name}"
    git -C "${dest}" fetch --all --prune
    git -C "${dest}" reset --hard origin/main 2>/dev/null || git -C "${dest}" reset --hard origin/master
  else
    log "Cloning ${name}"
    git clone "${url}" "${dest}"
  fi
}

build_dump1090() {
  log "[4/11] Build dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  pushd "${SRC_DIR}/dump1090" >/dev/null
  make -j"$(nproc)"
  install -m 755 dump1090 /usr/local/bin/dump1090-fa
  popd >/dev/null
}

build_dump978() {
  log "[5/11] Build dump978-fa"
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
  log "[6/11] Runtime directories"

  cat > "${TMPFILES_CONF}" <<EOF
d ${RUN_DIR} 0755 root root -
d ${RUN_DIR}/dump1090 0755 root root -
d ${RUN_DIR}/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# 6. Hotspot configs (installed, NOT switched live)
############################################################
install_hotspot_configs() {
  log "[7/11] Install hotspot configs (dnsmasq + hostapd)"

  # Minimal AP config (you can brand these later)
  install -d /etc/hostapd
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

  # Ensure dnsmasq includes /etc/dnsmasq.d
  if ! grep -q "^conf-dir=/etc/dnsmasq.d" /etc/dnsmasq.conf 2>/dev/null; then
    echo "conf-dir=/etc/dnsmasq.d,*.conf" >> /etc/dnsmasq.conf
  fi

  # hostapd service expects /etc/default/hostapd to point at config on some distros
  cat > /etc/default/hostapd <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

  # Unmask and enable dependencies (but do not start now)
  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable hostapd dnsmasq >/dev/null 2>&1 || true
}

############################################################
# 7. systemd units (ADS-B + UAT + net selector)
############################################################
install_systemd_units() {
  log "[8/11] Install systemd services"

  # dump1090 service
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

  # dump978 wrapper that writes latest.json
  cat > /usr/local/bin/homebase-dump978-cache <<EOF
#!/usr/bin/env bash
set -euo pipefail
install -d ${RUN_DIR}/dump978
OUT="${RUN_DIR}/dump978/latest.json"
# Keep last JSON line
stdbuf -oL -eL /usr/local/bin/dump978-fa --sdr driver=rtlsdr,index=1 --json-stdout \\
| while IFS= read -r line; do
    [[ -z "\${line}" ]] && continue
    printf '%s\n' "\${line}" > "\${OUT}.tmp"
    mv "\${OUT}.tmp" "\${OUT}"
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

  # "Normal" mode: stop AP services, ensure nothing forces wlan0 static IP
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

  # Hotspot mode: assign static IP to wlan0, start dnsmasq + hostapd
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

  # Boot-time selector (safe; avoids SSH drop)
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

  # Enable services. Start SDR services now (safe), but DO NOT switch network now.
  systemctl enable --now dump1090-fa dump978-fa nginx >/dev/null 2>&1 || true
  systemctl enable homebase-net-select.service >/dev/null 2>&1 || true
}

############################################################
# 8. Web UI + nginx
############################################################
deploy_web_app() {
  log "[9/11] Web UI"

  rsync -a --delete "${REPO_ROOT}/homebase-app/" "${WEB_ROOT}/"
  chown -R www-data:www-data "${WEB_ROOT}"

  local php_sock
  php_sock="$(detect_php_sock)"
  if [[ -z "${php_sock}" ]]; then
    echo "ERROR: Could not find PHP-FPM socket. Is php-fpm installed and running?"
    exit 1
  fi

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
# 9. Self-test
############################################################
self_test() {
  log "[10/11] Self-test"

  echo "Hostname: $(hostname)"
  hostname -f || true

  systemctl is-active ssh >/dev/null && echo "✔ SSH running" || echo "✖ SSH not running"
  systemctl is-active nginx >/dev/null && echo "✔ nginx running" || echo "✖ nginx not running"
  systemctl is-enabled dump1090-fa >/dev/null && echo "✔ dump1090 enabled" || echo "✖ dump1090 not enabled"
  systemctl is-enabled dump978-fa >/dev/null && echo "✔ dump978 enabled" || echo "✖ dump978 not enabled"

  echo
  echo "Network mode selector:"
  echo "  Boot flag path: ${BOOT_FLAG}"
  echo "  Enable hotspot for next boot:"
  echo "    sudo touch ${BOOT_FLAG} && sudo reboot"
  echo "  Return to normal mode on next boot:"
  echo "    sudo rm -f ${BOOT_FLAG} && sudo reboot"

  local ip
  ip="$(hostname -I | awk '{print $1}')"
  echo
  echo "Homebase UI:"
  echo "  http://homebase.local/"
  echo "  http://${ip}/"
}

############################################################
# 10. Final note (do not switch live)
############################################################
final_note() {
  log "[11/11] Done"
  echo
  echo "IMPORTANT:"
  echo "  Hotspot mode is selected at boot to prevent SSH dropouts."
  echo "  Do NOT run: systemctl start homebase-hotspot while SSH'd in."
  echo
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
install_hotspot_configs
install_systemd_units
deploy_web_app
self_test
final_note