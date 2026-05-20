#!/bin/bash
# RDK X5 WiFi configuration entry point (called by systemd)
# Checks if WiFi is connected; if not, starts AP mode for configuration.

DIR=/opt/wifi-config
PIDFILE=/tmp/wifi-config/flask.pid

log() { echo "[wifi-setup] $(date +%H:%M:%S) $*" | systemd-cat -t wifi-setup -p info || true; }

# Wait a moment for NetworkManager to auto-connect, then check
sleep 5
if ip route show default 2>/dev/null | grep -q wlan0; then
    log "WiFi connected (default route via wlan0). Nothing to do."
    exit 0
fi

log "WiFi not connected. Starting AP mode..."
python3 $DIR/ap_manager.py start $DIR 2>&1 | systemd-cat -t wifi-setup || true

log "Starting LED..."
python3 $DIR/status_led.py slow &
LEDPID=$!

log "Starting Flask..."
cd $DIR
python3 wifi_config.py &
FLASKPID=$!
echo $FLASKPID > $PIDFILE

wait $FLASKPID 2>/dev/null || true
RC=$?

log "Flask exited (code=$RC)."
kill $LEDPID 2>/dev/null || true
wait $LEDPID 2>/dev/null || true

# 143 = SIGTERM = user successfully configured WiFi, AP already stopped by connect API
# Any other code = Flask crashed or service stopped, need to tear down AP mode
if [ "$RC" != "143" ]; then
    log "Cleaning up AP mode..."
    python3 $DIR/ap_manager.py stop $DIR 2>&1 | systemd-cat -t wifi-setup || true
else
    log "WiFi configured successfully. Skipping AP cleanup."
fi

rm -f $PIDFILE
log "Finished."
exit 0