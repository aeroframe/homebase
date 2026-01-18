#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/opt/homebase/data/state.json"

if [[ -f "$STATE_FILE" ]] && grep -q '"setup_complete": *true' "$STATE_FILE"; then
  systemctl enable --now homebase-normal.service || true
  systemctl disable --now homebase-hotspot.service || true
else
  systemctl enable --now homebase-hotspot.service || true
  systemctl disable --now homebase-normal.service || true
fi