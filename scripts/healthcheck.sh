#!/usr/bin/env bash
set -euo pipefail

HOSTNAME_EXPECTED="homebase"
RUN_DIR="/run/homebase"
D1090_DIR="$RUN_DIR/dump1090"
D978_DIR="$RUN_DIR/dump978"
D1090_JSON="$D1090_DIR/aircraft.json"
D978_JSON="$D978_DIR/aircraft.json"

hr() { echo "------------------------------------------------------------"; }
ok() { echo "✔ $*"; }
warn() { echo "⚠ $*"; }
bad() { echo "✖ $*"; }

svc_active() { systemctl is-active --quiet "$1"; }

file_age_secs() {
  local f="$1"
  [[ -f "$f" ]] || { echo "-1"; return; }
  local now ts
  now="$(date +%s)"
  ts="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  echo $((now - ts))
}

file_size() {
  local f="$1"
  [[ -f "$f" ]] || { echo "-1"; return; }
  stat -c %s "$f" 2>/dev/null || echo -1
}

print_recent_journal_if_needed() {
  local unit="$1"
  echo
  echo "Last 20 log lines for $unit:"
  sudo journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
}

main() {
  hr
  echo "Homebase Health Check"
  echo "Time: $(date)"
  hr

  # Hostname
  local hn
  hn="$(hostname)"
  if [[ "$hn" == "$HOSTNAME_EXPECTED" ]]; then
	ok "Hostname is '$hn'"
  else
	warn "Hostname is '$hn' (expected '$HOSTNAME_EXPECTED')"
  fi

  # Avahi / mDNS
  if systemctl is-active --quiet avahi-daemon; then
	ok "avahi-daemon active (homebase.local should resolve on LAN)"
  else
	bad "avahi-daemon not active"
  fi

  # nginx
  if svc_active nginx; then
	ok "nginx active"
  else
	bad "nginx not active"
  fi

  # SDR detection
  if lsusb 2>/dev/null | grep -qiE '0bda:2832|rtl|realtek'; then
	ok "RTL-SDR detected (lsusb)"
	lsusb | grep -Ei '0bda:2832|rtl|realtek' || true
  else
	warn "No RTL-SDR detected via lsusb (ok if not plugged in)"
  fi

  hr

  # Determine mode
  local mode="none"
  if svc_active dump1090-fa; then
	mode="1090"
  elif svc_active dump978-fa; then
	mode="978"
  fi
  echo "ADS-B mode: $mode"

  # dump1090
  if svc_active dump1090-fa; then
	ok "dump1090-fa active"
  else
	warn "dump1090-fa not active"
  fi

  # dump978
  if svc_active dump978-fa; then
	ok "dump978-fa active"
  else
	warn "dump978-fa not active"
  fi

  hr

  # Output files check
  echo "Output files:"
  for f in "$D1090_JSON" "$D978_JSON"; do
	local sz age
	sz="$(file_size "$f")"
	age="$(file_age_secs "$f")"
	if [[ "$sz" -ge 0 ]]; then
	  echo " - $f  size=${sz}B  age=${age}s"
	else
	  echo " - $f  (missing)"
	fi
  done

  echo
  # Basic freshness logic
  if [[ "$mode" == "1090" ]]; then
	if [[ -f "$D1090_JSON" ]]; then
	  local age sz
	  age="$(file_age_secs "$D1090_JSON")"
	  sz="$(file_size "$D1090_JSON")"
	  if [[ "$age" -ge 0 && "$age" -le 30 && "$sz" -gt 0 ]]; then
		ok "1090 aircraft.json looks fresh (updated within 30s)"
	  elif [[ "$sz" -eq 0 ]]; then
		warn "1090 aircraft.json exists but is empty (check antenna/traffic; check logs)"
	  else
		warn "1090 aircraft.json not updating recently (age=${age}s). Check dump1090 logs."
	  fi
	else
	  warn "1090 aircraft.json missing (check dump1090 service and runtime dir)"
	fi
  elif [[ "$mode" == "978" ]]; then
	if [[ -f "$D978_JSON" ]]; then
	  local age sz
	  age="$(file_age_secs "$D978_JSON")"
	  sz="$(file_size "$D978_JSON")"
	  if [[ "$sz" -gt 0 ]]; then
		ok "978 output file is non-empty"
	  else
		warn "978 aircraft.json is empty. This can be normal if no UAT traffic is in range."
		echo "  Tip: 978 UAT is US-only, mostly GA, often low altitude; antenna placement matters a lot."
	  fi

	  if [[ "$age" -ge 0 && "$age" -le 60 ]]; then
		ok "978 aircraft.json file updated within 60s"
	  else
		warn "978 aircraft.json not updated recently (age=${age}s). Check dump978 logs."
	  fi
	else
	  warn "978 aircraft.json missing (check dump978 service and runtime dir)"
	fi
  else
	warn "Neither dump1090-fa nor dump978-fa appears active."
	echo "  Default start 1090:  sudo systemctl start dump1090-fa"
	echo "  Switch to 978:       sudo systemctl stop dump1090-fa && sudo systemctl start dump978-fa"
  fi

  hr

  # Print key unit info
  echo "Systemd ExecStart (for verification):"
  systemctl show dump1090-fa -p ExecStart --no-pager 2>/dev/null || true
  systemctl show dump978-fa  -p ExecStart --no-pager 2>/dev/null || true

  # If either service is failing, print logs
  if ! svc_active dump1090-fa; then
	print_recent_journal_if_needed dump1090-fa
  fi
  if ! svc_active dump978-fa; then
	print_recent_journal_if_needed dump978-fa
  fi

  hr
  echo "Done."
}

main "$@"