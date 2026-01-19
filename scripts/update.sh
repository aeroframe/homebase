#!/usr/bin/env bash
set -euo pipefail

cd /opt/homebase

echo "[0/6] Trust repo ownership"
git config --global --add safe.directory /opt/homebase || true

echo "[1/6] Pull latest code"
git fetch --all --prune
git reset --hard origin/main

echo "[2/6] Refresh web app"
mkdir -p /var/www/homebase
rsync -a --delete homebase-app/ /var/www/homebase/
chown -R www-data:www-data /var/www/homebase || true
chmod -R 755 /var/www/homebase || true

echo "[3/6] Install/refresh systemd units"
if compgen -G "systemd/homebase-*.service" > /dev/null; then
  install -m 644 systemd/homebase-*.service /etc/systemd/system/
fi

# Always refresh dump units from install.sh logic? keep simple: leave as-is.
# If you want update.sh to also refresh dump1090/dump978 units, uncomment:
# install -m 644 systemd/dump1090-fa.service /etc/systemd/system/ 2>/dev/null || true
# install -m 644 systemd/dump978-fa.service  /etc/systemd/system/ 2>/dev/null || true

systemctl daemon-reload

echo "[4/6] Restart services"
systemctl restart nginx || true
systemctl restart dump1090-fa || true
systemctl restart dump978-fa || true

# If boot unit exists, restart it
systemctl restart homebase-boot 2>/dev/null || true

echo "[5/6] Basic health checks"
systemctl is-active --quiet nginx && echo "✔ nginx active" || echo "✖ nginx inactive"
systemctl is-active --quiet dump1090-fa && echo "✔ dump1090 running (or restarting)" || echo "✖ dump1090 not running"
systemctl is-active --quiet dump978-fa  && echo "✔ dump978 running (or restarting)"  || echo "✖ dump978 not running"

echo "[6/6] Done"
echo "Homebase updated."