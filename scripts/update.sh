#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/homebase"
WEB_ROOT="/var/www/homebase"

log() {
  echo -e "\n[$(date '+%H:%M:%S')] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
	echo "Please run with sudo: sudo ./scripts/update.sh"
	exit 1
  fi
}

log "=============================="
log " Homebase Update (Aeroframe)"
log "=============================="

require_root
cd "${REPO_DIR}"

# -------------------------------------------------
# [1/7] Pull latest code
# -------------------------------------------------
log "[1/7] Pull latest code"
git config --global --add safe.directory "${REPO_DIR}" || true
git fetch origin
git reset --hard origin/main

# -------------------------------------------------
# [2/7] Update web app (Homebase UI + auth)
# -------------------------------------------------
log "[2/7] Refresh web application"

install -d "${WEB_ROOT}"
rsync -a --delete homebase-app/ "${WEB_ROOT}/"

# Permissions for nginx + php-fpm
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

# -------------------------------------------------
# [3/7] Update nginx config (if present)
# -------------------------------------------------
if [[ -f nginx/homebase.conf ]]; then
  log "[3/7] Update nginx site config"
  install -m 644 nginx/homebase.conf /etc/nginx/sites-available/homebase
  ln -sf /etc/nginx/sites-available/homebase /etc/nginx/sites-enabled/homebase
  rm -f /etc/nginx/sites-enabled/default || true
fi

# -------------------------------------------------
# [4/7] Update systemd units
# -------------------------------------------------
log "[4/7] Update systemd services"

if [[ -d systemd ]]; then
  install -m 644 systemd/*.service /etc/systemd/system/
fi

systemctl daemon-reload

# -------------------------------------------------
# [5/7] Update network configs (optional)
# -------------------------------------------------
log "[5/7] Update network configs (if present)"

if [[ -d network ]]; then
  install -m 644 network/dnsmasq-homebase.conf /etc/dnsmasq.d/homebase.conf 2>/dev/null || true
  install -m 644 network/hostapd.conf /etc/hostapd/hostapd.conf 2>/dev/null || true
  install -m 644 network/dhcpcd-homebase.conf /etc/dhcpcd.conf.d/homebase.conf 2>/dev/null || true
fi

# -------------------------------------------------
# [6/7] Restart services (order matters)
# -------------------------------------------------
log "[6/7] Restart services"

systemctl restart nginx

# Homebase control services (if present)
systemctl restart homebase-boot.service     2>/dev/null || true
systemctl restart homebase-normal.service   2>/dev/null || true
systemctl restart homebase-hotspot.service  2>/dev/null || true

# SDR services (non-fatal if SDR not attached)
systemctl restart dump1090-fa.service  || true
systemctl restart dump978-fa.service   || true

# -------------------------------------------------
# [7/7] Post-update self-test
# -------------------------------------------------
log "[7/7] Self-test"

fail=0

command -v dump1090-fa >/dev/null || { echo "✖ dump1090-fa missing"; fail=1; }
command -v dump978-fa  >/dev/null || { echo "✖ dump978-fa missing";  fail=1; }

[[ -d /run/homebase ]] || { echo "✖ /run/homebase missing"; fail=1; }

curl -fs http://localhost/ >/dev/null || { echo "✖ Web UI unreachable"; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "✔ Homebase update successful"
else
  echo "⚠ Homebase update completed with warnings"
fi

echo
echo "Access:"
echo "  http://homebase.local/  (if mDNS enabled)"
echo "  http://<device-ip>/"

exit 0