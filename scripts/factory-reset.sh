#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo " Homebase Factory Reset"
echo "======================================"
echo "This wipes Wi-Fi + user pairing, not firmware."

read -p "Type RESET to confirm: " CONFIRM
if [[ "$CONFIRM" != "RESET" ]]; then
  echo "Cancelled."
  exit 1
fi

rm -f /opt/homebase/data/state.json
rm -f /opt/homebase/data/wifi.json

systemctl enable --now homebase-hotspot.service || true
systemctl disable --now homebase-normal.service || true

echo "Reset complete. Rebooting..."
reboot