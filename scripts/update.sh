#!/usr/bin/env bash
set -euo pipefail

cd /opt/homebase

echo "[1/5] Pull latest code"
git pull

echo "[2/5] Refresh web app"
mkdir -p /var/www/homebase
rsync -a --delete homebase-app/ /var/www/homebase/
chown -R www-data:www-data /var/www/homebase
chmod -R 755 /var/www/homebase

echo "[3/5] Reload systemd units"
install -m 644 systemd/*.service /etc/systemd/system/
systemctl daemon-reload

echo "[4/5] Restart services"
systemctl restart homebase-api || true
systemctl restart nginx || true
systemctl restart dump1090-fa || true
systemctl restart dump978-fa || true

echo "[5/5] Done"
echo "Homebase updated."