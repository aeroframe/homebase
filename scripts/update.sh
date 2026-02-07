#!/usr/bin/env bash
set -euo pipefail

cd /opt/homebase

echo "[0/7] Trust repo ownership"
git config --global --add safe.directory /opt/homebase || true

echo "[1/7] Pull latest code"
git fetch --all --prune
git reset --hard origin/main

echo "[2/7] Refresh web app"
mkdir -p /var/www/homebase
rsync -a --delete homebase-app/ /var/www/homebase/
chown -R www-data:www-data /var/www/homebase || true
chmod -R 755 /var/www/homebase || true

echo "[3/7] Install/refresh systemd units"

# Homebase units (if present)
if compgen -G "systemd/homebase-*.service" > /dev/null; then
  install -m 644 systemd/homebase-*.service /etc/systemd/system/
fi

# Dump units (always refresh if present)
if [[ -f "systemd/dump1090-fa.service" ]]; then
  install -m 644 systemd/dump1090-fa.service /etc/systemd/system/dump1090-fa.service
fi

if [[ -f "systemd/dump978-fa.service" ]]; then
  install -m 644 systemd/dump978-fa.service /etc/systemd/system/dump978-fa.service
fi

systemctl daemon-reload

echo "[4/7] Restart services"
systemctl restart nginx || true

# Restart only the active ADS-B receiver to avoid SDR contention.
# Priority:
#  1) If dump1090 is active -> restart dump1090 only
#  2) Else if dump978 is active -> restart dump978 only
#  3) Else restart dump1090 (default) and leave dump978 stopped
if systemctl is-active --quiet dump1090-fa; then
  systemctl restart dump1090-fa || true
elif systemctl is-active --quiet dump978-fa; then
  systemctl restart dump978-fa || true
else
  # Default to 1090 on systems with a single SDR
  systemctl restart dump1090-fa || true
  systemctl stop dump978-fa 2>/dev/null || true
fi

# If boot unit exists, restart it
systemctl restart homebase-boot 2>/dev/null || true

echo "[5/7] Ensure runtime directories exist"
mkdir -p /run/homebase/dump1090 /run/homebase/dump978
chmod 755 /run/homebase /run/homebase/dump1090 /run/homebase/dump978 || true

echo "[6/7] Basic health checks"
systemctl is-active --quiet nginx && echo "✔ nginx active" || echo "✖ nginx inactive"

# Determine active ADS-B mode
MODE="none"
if systemctl is-active --quiet dump1090-fa; then
  MODE="1090"
elif systemctl is-active --quiet dump978-fa; then
  MODE="978"
fi
echo "ADS-B mode: ${MODE}"

# dump1090
if systemctl is-active --quiet dump1090-fa; then
  echo "✔ dump1090-fa active"
else
  echo "✖ dump1090-fa not active"
fi

# dump978
if systemctl is-active --quiet dump978-fa; then
  echo "✔ dump978-fa active"
else
  echo "✖ dump978-fa not active"
fi

echo
echo "Dump unit ExecStart lines (for verification):"
systemctl show dump1090-fa -p ExecStart --no-pager 2>/dev/null || true
systemctl show dump978-fa  -p ExecStart --no-pager 2>/dev/null || true

echo "[7/7] Done"
echo "Homebase updated."