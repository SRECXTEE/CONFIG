#!/bin/bash
# Teardown script for RDK X5 WiFi configuration (called by systemd ExecStop)

CONFIG_DIR="/opt/wifi-config"
FLASK_PID_FILE="/tmp/wifi-config/flask.pid"

log() { echo "[wifi-setup] $(date '+%H:%M:%S') $*" | systemd-cat -t wifi-setup -p info; }

log "Stopping WiFi configuration service..."

# Kill Flask if running
if [ -f "$FLASK_PID_FILE" ]; then
    PID=$(cat "$FLASK_PID_FILE")
    kill $PID 2>/dev/null || true
    rm -f "$FLASK_PID_FILE"
fi

# Force-stop AP mode (cleanup iptables, hostapd, dnsmasq)
python3 "$CONFIG_DIR/ap_manager.py" stop "$CONFIG_DIR" 2>/dev/null || true

# Kill any remaining dnsmasq/hostapd on WiFi interfaces
pkill -f "hostapd.*wifi-config" 2>/dev/null || true
pkill -f "dnsmasq.*wifi-config" 2>/dev/null || true

log "WiFi configuration service stopped."
exit 0