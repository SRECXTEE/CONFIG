#!/usr/bin/env python3
"""Flask captive portal for RDK X5 WiFi configuration."""

import subprocess
import os
import json
import sys
import re
import time
from flask import Flask, render_template, request, jsonify, redirect

app = Flask(__name__)

# Captive portal detection paths that must return the portal page
CAPTIVE_PATHS = {
    "/", "/generate_204", "/hotspot-detect.html", "/connecttest.txt",
    "/ncsi.txt", "/success.txt", "/canonical.html", "/fwlink/",
}

FAILURE_COUNT = {}
MAX_FAILURES = 3


def _run(*args, timeout=30):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def _get_current_connection():
    """Check current WiFi connection status."""
    result = _run("nmcli", "-t", "-f", "GENERAL.STATE", "general")
    if "connected" in result.stdout:
        # Get SSID and IP
        ssid_result = _run("nmcli", "-t", "-f", "GENERAL.CONNECTION", "general")
        ssid = ssid_result.stdout.strip().split(":")[-1] if ":" in ssid_result.stdout else ""
        ip_result = _run("nmcli", "-t", "-f", "IP4.ADDRESS", "device", "show", "wlan0")
        ip = ip_result.stdout.strip().split(":")[-1].split("/")[0] if ":" in ip_result.stdout else ""
        return True, ssid, ip
    return False, "", ""


@app.route("/")
@app.route("/generate_204")
@app.route("/hotspot-detect.html")
@app.route("/connecttest.txt")
@app.route("/ncsi.txt")
@app.route("/success.txt")
@app.route("/canonical.html")
@app.route("/fwlink/")
@app.route("/fwlink/<path:subpath>")
def portal(subpath=None):
    return render_template("index.html")


@app.route("/api/scan")
def api_scan():
    """Scan for available WiFi networks using iw (works in AP mode)."""
    # Determine wifi interface
    iface = "wlan0"
    iface_file = "/tmp/wifi-config/iface"
    if os.path.exists(iface_file):
        with open(iface_file) as f:
            iface = f.read().strip()

    # Trigger scan
    _run("iw", "dev", iface, "scan")
    time.sleep(2)

    # Dump scan results
    result = _run("iw", "dev", iface, "scan", "dump")
    networks = []
    seen = set()
    current = {}

    for line in result.stdout.split("\n"):
        line = line.strip()

        # Start of a new BSS block
        if line.startswith("BSS ") and "(on " in line:
            if current.get("ssid"):
                ssid = current["ssid"]
                if ssid not in seen and not ssid.startswith("RDK-X5-Setup"):
                    seen.add(ssid)
                    networks.append({
                        "ssid": ssid,
                        "signal": current.get("signal", 0),
                        "security": current.get("security", ""),
                    })
            current = {}

        # SSID
        if "SSID:" in line:
            ssid = line.split("SSID:", 1)[1].strip()
            if "\\x00" in ssid:  # hidden SSID
                continue
            current["ssid"] = ssid

        # Signal
        if "signal:" in line:
            val = re.search(r"signal:\s*(-?\d+)", line)
            if val:
                # Convert dBm (-100 to -30) to percentage scale
                dbm = int(val.group(1))
                current["signal"] = max(0, min(100, (dbm + 100) * 100 // 70))

        # Security (WPA/RSN present = encrypted)
        if "RSN:" in line:
            current["security"] = "WPA2"
        if "WPA:" in line and current.get("security") != "WPA2":
            current["security"] = "WPA"

    # Don't forget the last BSS
    if current.get("ssid"):
        ssid = current["ssid"]
        if ssid not in seen and not ssid.startswith("RDK-X5-Setup"):
            seen.add(ssid)
            networks.append({
                "ssid": ssid,
                "signal": current.get("signal", 0),
                "security": current.get("security", ""),
            })

    networks.sort(key=lambda n: n["signal"], reverse=True)
    return jsonify(networks)


@app.route("/api/connect", methods=["POST"])
def api_connect():
    """Attempt to connect to a WiFi network."""
    data = request.get_json(silent=True) or {}
    if not data:
        data = request.form.to_dict()

    ssid = (data.get("ssid", "") or "").strip()
    password = (data.get("password", "") or "").strip()

    if not ssid:
        return jsonify({"success": False, "message": "SSID is required"}), 400

    # Tear down AP mode first to free the interface
    _run("python3", "/opt/wifi-config/ap_manager.py", "stop", "/opt/wifi-config")

    # Wait for NetworkManager to take over
    time.sleep(5)

    # Remove old connection profile if exists
    _run("nmcli", "connection", "delete", ssid)

    # Create a new connection profile with SSID as the name
    if password:
        _run("nmcli", "connection", "add", "type", "wifi", "con-name", ssid,
             "ifname", "wlan0", "ssid", ssid,
             "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password,
             "autoconnect", "yes")
    else:
        _run("nmcli", "connection", "add", "type", "wifi", "con-name", ssid,
             "ifname", "wlan0", "ssid", ssid,
             "autoconnect", "yes")

    # Activate the connection
    result = _run("nmcli", "connection", "up", ssid, timeout=30)

    if result.returncode == 0:
        FAILURE_COUNT.pop(ssid, None)
        time.sleep(2)
        connected, conn_ssid, ip = _get_current_connection()
        return jsonify({
            "success": True,
            "message": "Connected successfully" if connected else "Activating...",
            "ssid": conn_ssid,
            "ip": ip,
        })
    else:
        FAILURE_COUNT[ssid] = FAILURE_COUNT.get(ssid, 0) + 1
        error = result.stderr.lower()

        if "secrets" in error or "password" in error or "auth" in error:
            msg = "Incorrect password. Please try again."
        elif "not found" in error or "no network" in error:
            msg = "Network not found or out of range."
        elif "timeout" in error:
            msg = "Connection timed out. Please check the password and try again."
        else:
            msg = "Connection failed. Please try again."

        if FAILURE_COUNT.get(ssid, 0) >= MAX_FAILURES:
            msg += " (Multiple failures. Consider checking your password or selecting a different network.)"

        return jsonify({"success": False, "message": msg}), 400


@app.route("/api/status")
def api_status():
    """Return current connection status."""
    connected, ssid, ip = _get_current_connection()
    return jsonify({
        "connected": connected,
        "ssid": ssid,
        "ip": ip,
        "mode": "client" if connected else "ap",
    })


@app.route("/api/reset", methods=["POST"])
def api_reset():
    """Forget WiFi and trigger re-configuration."""
    connected, ssid, _ = _get_current_connection()
    if connected:
        _run("nmcli", "connection", "delete", ssid)
    return jsonify({"success": True, "message": "WiFi forgotten. System will reconfigure."})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)