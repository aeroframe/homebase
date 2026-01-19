#!/usr/bin/env bash
set -euo pipefail

############################################################
# Homebase Installer (Aeroframe)
# Raspberry Pi OS / Debian (Trixie)
#
# SAFE DESIGN:
# - Never switches networking live
# - Hotspot only enabled at boot
# - Auto-detects Wi-Fi interface
# - Validates AP before enabling
# - Auto-reverts if hotspot fails
############################################################

TARGET_HOSTNAME="homebase"
HOTSPOT_SSID="Homebase"
HOTSPOT_PASS="homebase1234"
HOTSPOT_IP="10.42.0.1"
FAILSAFE_SECONDS=120

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
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
}

apt_run() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

############################################################
# Detect Wi-Fi interface (CRITICAL)
############################################################
detect_wifi_iface() {
  local iface
  iface="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wl' | head -n1)"
  [[ -n "$iface" ]] || die "No Wi-Fi interface detected"
  echo "$iface"
}

############################################################
# 0. Baseline system
############################################################
baseline_system() {
  log "[0/12] Baseline system"

  apt_run update -y
  apt_run install -y openssh-server avahi-daemon avahi-utils rfkill iw locales

  systemctl enable --now ssh

  hostnamectl set-hostname "$TARGET_HOSTNAME"
  sed -i "s/^127.0.1.1.*/127.0.1.1 $TARGET_HOSTNAME/" /etc/hosts || \
    echo "127.0.1.1 $TARGET_HOSTNAME" >> /etc/hosts

  systemctl restart avahi-daemon
}

############################################################
# 1. Packages
############################################################
install_packages() {
  log "[1/12] Installing packages"

  apt_run update -y
  apt_run upgrade -y

  apt_run install -y \
    git curl rsync \
    nginx php-fpm \
    dnsmasq hostapd \
    build-essential cmake pkg-config \
    librtlsdr-dev libusb-1.0-0-dev libncurses-dev libboost-all-dev \
    libsoapysdr-dev soapysdr-tools \
    soapysdr0.8-module-rtlsdr soapysdr0.8-module-all

  systemctl unmask hostapd || true
}

############################################################
# 2. Directories
############################################################
prepare_dirs() {
  log "[2/12] Directories"
  install -d "$SRC_DIR" "$WEB_ROOT" "$RUN_DIR"
}

############################################################
# 3–4. SDR Builds (unchanged logic)
############################################################
clone_or_update() {
  local name="$1" url="$2" dest="$SRC_DIR/$name"
  [[ -d "$dest/.git" ]] && git -C "$dest" reset --hard origin/main || git clone "$url" "$dest"
}

build_dump1090() {
  log "[3/12] dump1090-fa"
  clone_or_update dump1090 https://github.com/flightaware/dump1090.git
  make -C "$SRC_DIR/dump1090" -j"$(nproc)"
  install -m755 "$SRC_DIR/dump1090/dump1090" /usr/local/bin/dump1090-fa
}

build_dump978() {
  log "[4/12] dump978-fa"
  clone_or_update dump978 https://github.com/flightaware/dump978.git
  make -C "$SRC_DIR/dump978" -j"$(nproc)"
  install -m755 "$SRC_DIR/dump978/dump978-fa" /usr/local/bin/dump978-fa
}

############################################################
# 5. Runtime dirs
############################################################
setup_tmpfiles() {
  log "[5/12] Runtime dirs"
  cat > "$TMPFILES_CONF" <<EOF
d $RUN_DIR 0755 root root -
d $RUN_DIR/dump1090 0755 root root -
d $RUN_DIR/dump978 0755 root root -
EOF
  systemd-tmpfiles --create
}

############################################################
# 6. Hotspot configs (AUTO-IFACE)
############################################################
install_hotspot_configs() {
  log "[6/12] Hotspot configs"

  WIFI_IF="$(detect_wifi_iface)"
  log "Detected Wi-Fi interface: $WIFI_IF"

  rfkill unblock wifi || true
  iw reg set US || true

  install -d /etc/hostapd

  cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSPOT_SSID
hw_mode=g
channel=6
country_code=US
ieee80211d=1
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$HOTSPOT_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  cat > /etc/dnsmasq.d/homebase.conf <<EOF
interface=$WIFI_IF
dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,24h
address=/homebase.local/$HOTSPOT_IP
EOF

  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd
}

############################################################
# 7. Network selector + FAILSAFE
############################################################
install_net_selector() {
  log "[7/12] Network selector + failsafe"

  WIFI_IF="$(detect_wifi_iface)"

  cat > /usr/local/sbin/homebase-net-select <<EOF
#!/usr/bin/env bash
set -euo pipefail

FLAG="$BOOT_FLAG"

if [[ -f "\$FLAG" ]]; then
  ip addr add $HOTSPOT_IP/24 dev $WIFI_IF || true
  ip link set $WIFI_IF up
  systemctl start dnsmasq hostapd

  # FAILSAFE
  (
    sleep $FAILSAFE_SECONDS
    if ! iw dev $WIFI_IF station dump | grep -q Station; then
      rm -f "\$FLAG"
      reboot
    fi
  ) &
else
  systemctl stop hostapd dnsmasq || true
fi
EOF

  chmod +x /usr/local/sbin/homebase-net-select

  cat > /etc/systemd/system/homebase-net-select.service <<'EOF'
[Unit]
Before=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homebase-net-select

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable homebase-net-select.service
}

############################################################
# 8. Web UI
############################################################
deploy_web_app() {
  log "[8/12] Web UI"
  rsync -a --delete "$REPO_ROOT/homebase-app/" "$WEB_ROOT/"
  chown -R www-data:www-data "$WEB_ROOT"
  systemctl restart nginx
}

############################################################
# 9. Self-test
############################################################
self_test() {
  log "[9/12] Self-test"
  echo "Wi-Fi IF: $(detect_wifi_iface)"
  echo "Hotspot flag: $BOOT_FLAG"
  echo "Enable hotspot:"
  echo "  sudo touch $BOOT_FLAG && sudo reboot"
}

############################################################
# RUN
############################################################
require_root
baseline_system
install_packages
prepare_dirs
build_dump1090
build_dump978
setup_tmpfiles
install_hotspot_configs
install_net_selector
deploy_web_app
self_test