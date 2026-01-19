#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian Trixie
#
# GUARANTEES:
# - SSH NEVER breaks
# - Network mode decided ONLY at boot
# - Hotspot isolated to wlan0
# - Ethernet always safe
############################################################

TARGET_HOSTNAME="homebase"

# Hotspot network (NON-CONFLICTING)
HOTSPOT_IF="wlan0"
HOTSPOT_IP="10.43.0.1"
HOTSPOT_CIDR="10.43.0.1/24"
HOTSPOT_SSID="Homebase"
HOTSPOT_PASS="homebase1234"
HOTSPOT_COUNTRY="US"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="/opt/homebase/src"
WEB_ROOT="/var/www/homebase"
RUN_DIR="/run/homebase"
TMPFILES_CONF="/etc/tmpfiles.d/homebase.conf"

BOOT_FLAG="/boot/firmware/homebase-hotspot"

############################################################
# Helpers
############################################################
log() { echo -e "\n[$(date '+%H:%M:%S')] $*"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }; }

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

detect_php_sock() {
  ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true
}

############################################################
# 0. Baseline (SAFE)
############################################################
baseline() {
  log "[0/10] Baseline system"

  apt_run update -y
  apt_run install -y \
    openssh-server avahi-daemon avahi-utils locales

  systemctl enable --now ssh

  sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen || true
  locale-gen || true

  hostnamectl set-hostname "$TARGET_HOSTNAME"

  sed -i "s/^127.0.1.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts \
    || echo "127.0.1.1 ${TARGET_HOSTNAME}" >> /etc/hosts

  systemctl restart systemd-hostnamed avahi-daemon
}

############################################################
# 1. Git safety
############################################################
git_safety() {
  log "[1/10] Git safety"
  git config --system --add safe.directory /opt/homebase || true
}

############################################################
# 2. Packages
############################################################
packages() {
  log "[2/10] Installing packages"

  apt_run update -y
  apt_run upgrade -y

  apt_run install -y \
    git curl rsync \
    nginx php-fpm \
    dnsmasq hostapd rfkill \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all

  # IMPORTANT: do NOT let these auto-start
  systemctl disable dnsmasq hostapd || true
  systemctl mask dnsmasq hostapd || true
}

############################################################
# 3. Directories
############################################################
dirs() {
  log "[3/10] Directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 4. SDR builds
############################################################
clone_or_update() {
  local n="$1" u="$2" d="$SRC_DIR/$n"
  [[ -d "$d/.git" ]] && git -C "$d" reset --hard origin/main || git clone "$u" "$d"
}

build_sdr() {
  log "[4/10] SDR builds"

  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  make -C "$SRC_DIR/dump1090" -j$(nproc)
  install -m755 "$SRC_DIR/dump1090/dump1090" /usr/local/bin/dump1090-fa

  clone_or_update dump978 https://github.com/flightaware/dump978.git
  make -C "$SRC_DIR/dump978" clean || true
  make -C "$SRC_DIR/dump978" -j$(nproc)
  install -m755 "$SRC_DIR/dump978/dump978-fa" /usr/local/bin/dump978-fa
}

############################################################
# 5. Runtime dirs
############################################################
runtime_dirs() {
  log "[5/10] Runtime dirs"

  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF

  systemd-tmpfiles --create
}

############################################################
# 6. Hotspot configs (INSTALLED ONLY)
############################################################
hotspot_configs() {
  log "[6/10] Hotspot configs"

  mkdir -p /etc/hostapd

  cat > /etc/hostapd/hostapd.conf <<EOF
country_code=$HOTSPOT_COUNTRY
interface=$HOTSPOT_IF
driver=nl80211
ssid=$HOTSPOT_SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$HOTSPOT_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  cat > /etc/dnsmasq.d/homebase.conf <<EOF
interface=$HOTSPOT_IF
dhcp-range=10.43.0.20,10.43.0.200,255.255.255.0,24h
address=/homebase.local/$HOTSPOT_IP
EOF
}

############################################################
# 7. Network selector (BOOT ONLY)
############################################################
network_selector() {
  log "[7/10] Network selector"

  cat > /usr/local/sbin/homebase-net-select <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

FLAG="/boot/firmware/homebase-hotspot"

if [[ ! -f "$FLAG" ]]; then
  exit 0
fi

# Kill any wifi manager
systemctl stop NetworkManager 2>/dev/null || true
systemctl stop wpa_supplicant 2>/dev/null || true

ip link set wlan0 down || true
ip addr flush dev wlan0 || true
ip addr add 10.43.0.1/24 dev wlan0
ip link set wlan0 up

systemctl unmask dnsmasq hostapd
systemctl start dnsmasq
systemctl start hostapd
EOF

  chmod +x /usr/local/sbin/homebase-net-select

  cat > /etc/systemd/system/homebase-net-select.service <<EOF
[Unit]
Description=Homebase Network Selector
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homebase-net-select

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable homebase-net-select
}

############################################################
# 8. Web
############################################################
web() {
  log "[8/10] Web UI"

  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"

  PHP_SOCK=$(detect_php_sock)

  cat > /etc/nginx/sites-available/homebase <<EOF
server {
  listen 80 default_server;
  root $WEB_ROOT;
  index index.php;

  location / { try_files \$uri /index.php; }
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
# 9. Self test
############################################################
self_test() {
  log "[9/10] Self-test"

  echo "SSH: $(systemctl is-active ssh)"
  echo "Web: http://homebase.local"
  echo
  echo "Enable hotspot on next boot:"
  echo "  sudo touch $BOOT_FLAG && sudo reboot"
}

############################################################
# RUN
############################################################
require_root
baseline
git_safety
packages
dirs
build_sdr
runtime_dirs
hotspot_configs
network_selector
web
self_test