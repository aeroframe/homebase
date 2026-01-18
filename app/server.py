#!/usr/bin/env python3
import json, os, socket, subprocess, time
from flask import Flask, request, jsonify, send_from_directory

APP = Flask(__name__)

STATE_FILE = "/opt/homebase/data/state.json"
WIFI_FILE  = "/opt/homebase/data/wifi.json"
AEROFRAME_LOGIN_URL = os.environ.get("AEROFRAME_LOGIN_URL", "https://aerofra.me/api/auth/login.php")

def sh(cmd, check=True):
	p = subprocess.run(cmd, capture_output=True, text=True)
	if check and p.returncode != 0:
		raise RuntimeError(p.stderr.strip() or "command failed")
	return p.stdout.strip()

def read_json(path, default):
	try:
		with open(path) as f:
			return json.load(f)
	except Exception:
		return default

def write_json(path, obj):
	os.makedirs(os.path.dirname(path), exist_ok=True)
	tmp = path + ".tmp"
	with open(tmp, "w") as f:
		json.dump(obj, f, indent=2)
	os.replace(tmp, path)

def lan_ip():
	# Try to detect a "real" LAN IP (not hotspot)
	try:
		out = sh(["bash","-lc","hostname -I | awk '{print $1}'"], check=False).strip()
		return out or None
	except Exception:
		return None

@APP.get("/api/status")
def status():
	st = read_json(STATE_FILE, {"setup_complete": False})
	return jsonify({
		"setup_complete": bool(st.get("setup_complete", False)),
		"ip": lan_ip()
	})

@APP.post("/api/save_wifi")
def save_wifi():
	d = request.get_json(force=True, silent=True) or {}
	ssid = (d.get("ssid") or "").strip()
	password = d.get("password") or ""
	if not ssid or not password:
		return jsonify(success=False, error="Missing Wi-Fi SSID or password"), 400
	write_json(WIFI_FILE, {"ssid": ssid, "password": password})
	return jsonify(success=True)

@APP.post("/api/connect_wifi")
def connect_wifi():
	wifi = read_json(WIFI_FILE, {})
	ssid = wifi.get("ssid")
	psk = wifi.get("password")
	if not ssid or not psk:
		return jsonify(success=False, error="No Wi-Fi saved"), 400

	conf = f'''ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={{
	ssid="{ssid}"
	psk="{psk}"
}}
'''
	sh(["sudo","bash","-lc", f"cat > /etc/wpa_supplicant/wpa_supplicant.conf <<'EOF'\n{conf}\nEOF"])
	sh(["sudo","wpa_cli","-i","wlan0","reconfigure"], check=False)
	time.sleep(6)

	ip = lan_ip()
	if not ip:
		return jsonify(success=False, error="Wi-Fi not connected yet"), 409

	return jsonify(success=True, ip=ip)

@APP.post("/api/login")
def api_login():
	data = request.get_json(force=True, silent=True) or {}
	email = (data.get("email") or "").strip()
	password = data.get("password") or ""

	if not email or not password:
		return jsonify(success=False, error="Missing email or password"), 400

	payload = json.dumps({"email": email, "password": password}).encode("utf-8")

	try:
		import urllib.request
		req = urllib.request.Request(
			AEROFRAME_LOGIN_URL,
			data=payload,
			headers={"Content-Type": "application/json", "User-Agent": "Homebase/0.1-beta"},
			method="POST"
		)
		with urllib.request.urlopen(req, timeout=10) as resp:
			body = resp.read().decode("utf-8")
		result = json.loads(body)
	except Exception as e:
		return jsonify(success=False, error=f"Login service unreachable: {e}"), 502

	if not result.get("success"):
		return jsonify(success=False, error=result.get("error", "Invalid credentials.")), 401

	user = result.get("user") or {}
	if not user.get("email") or not user.get("account_type"):
		return jsonify(success=False, error="Malformed login response"), 502

	st = read_json(STATE_FILE, {})
	st["user"] = {
		"id": user.get("id"),
		"email": user.get("email"),
		"account_type": user.get("account_type")
	}
	write_json(STATE_FILE, st)

	return jsonify(success=True, user={"email": user["email"], "account_type": user["account_type"]})

@APP.post("/api/finish_setup")
def finish_setup():
	st = read_json(STATE_FILE, {})
	st["setup_complete"] = True
	write_json(STATE_FILE, st)

	sh(["sudo","systemctl","enable","--now","homebase-normal.service"], check=False)
	sh(["sudo","systemctl","disable","--now","homebase-hotspot.service"], check=False)

	return jsonify(success=True)

@APP.get("/")
def setup_root():
	return send_from_directory("/opt/homebase/app/ui", "index.html")

@APP.get("/<path:p>")
def setup_assets(p):
	return send_from_directory("/opt/homebase/app/ui", p)

if __name__ == "__main__":
	APP.run(host="0.0.0.0", port=8080)