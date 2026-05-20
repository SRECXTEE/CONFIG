#!/bin/bash
# One-click deployment script for RDK X5 WiFi configuration
# Run on the RDK X5 board: sudo bash install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/wifi-config"

echo "========================================="
echo " RDK X5 WiFi Configuration Installer"
echo "========================================="
echo ""

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo bash install.sh)"
    exit 1
fi

echo "[1/5] Checking system dependencies..."

# Check and install each dependency individually, skip on failure
MISSING=""
for pkg in hostapd dnsmasq; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    echo "  Installing missing packages:$MISSING"
    apt-get update -qq 2>/dev/null || true
    # Install one by one, ignore failures
    for pkg in $MISSING; do
        apt-get install -y -qq "$pkg" 2>/dev/null && echo "  $pkg: OK" || echo "  $pkg: FAILED (may need manual install)"
    done
else
    echo "  hostapd, dnsmasq: OK"
fi

# Install Flask: try multiple methods, check result after each
echo "  Installing Flask..."
FLASK_OK=0

# Method 1: pip3 (older versions without --break-system-packages)
pip3 install flask 2>/dev/null
python3 -c "import flask" 2>/dev/null && FLASK_OK=1

# Method 2: pip3 with --break-system-packages (newer pip)
if [ $FLASK_OK -eq 0 ]; then
    pip3 install flask --break-system-packages 2>/dev/null
    python3 -c "import flask" 2>/dev/null && FLASK_OK=1
fi

# Method 3: pip3 --user (externally-managed systems)
if [ $FLASK_OK -eq 0 ]; then
    pip3 install flask --user 2>/dev/null
    python3 -c "import flask" 2>/dev/null && FLASK_OK=1
fi

# Method 4: apt
if [ $FLASK_OK -eq 0 ]; then
    apt-get install -y -qq python3-flask 2>/dev/null
    python3 -c "import flask" 2>/dev/null && FLASK_OK=1
fi

if [ $FLASK_OK -eq 1 ]; then
    echo "  flask: OK"
else
    echo "  flask: FAILED"
fi

echo "  Done."

echo "[2/5] Creating installation directory..."
mkdir -p "$INSTALL_DIR/templates"
echo "  Done."

echo "[3/5] Copying files..."
cp "$SCRIPT_DIR/wifi_config.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/ap_manager.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/status_led.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/hostapd.conf" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/dnsmasq.conf" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/start_wifi_setup.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/stop_wifi_setup.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/templates/index.html" "$INSTALL_DIR/templates/"
chmod +x "$INSTALL_DIR/start_wifi_setup.sh"
chmod +x "$INSTALL_DIR/stop_wifi_setup.sh"
echo "  Done."

echo "[4/5] Installing systemd service..."
cp "$SCRIPT_DIR/wifi-setup.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable wifi-setup.service
echo "  Done."

echo "[5/5] Verifying installation..."
ERRORS=0

# Check each component
echo -n "  hostapd: "
which hostapd &>/dev/null && echo "OK" || { echo "MISSING"; ERRORS=$((ERRORS+1)); }

echo -n "  dnsmasq: "
which dnsmasq &>/dev/null && echo "OK" || { echo "MISSING"; ERRORS=$((ERRORS+1)); }

echo -n "  Flask: "
if python3 -c "import flask" 2>/dev/null; then
    echo "OK"
else
    # Last-resort retry
    pip3 install flask --user 2>/dev/null || true
    pip3 install flask 2>/dev/null || true
    apt-get install -y -qq python3-flask 2>/dev/null || true
    if python3 -c "import flask" 2>/dev/null; then
        echo "OK"
    else
        echo "MISSING"
        ERRORS=$((ERRORS+1))
    fi
fi

echo -n "  nmcli: "
which nmcli &>/dev/null && echo "OK" || { echo "MISSING"; ERRORS=$((ERRORS+1)); }

echo -n "  iptables: "
which iptables &>/dev/null && echo "OK" || { echo "MISSING"; ERRORS=$((ERRORS+1)); }

echo -n "  service: "
systemctl is-enabled wifi-setup.service &>/dev/null && echo "OK" || { echo "MISSING"; ERRORS=$((ERRORS+1)); }

echo ""

if [ $ERRORS -gt 0 ]; then
    echo "! $ERRORS component(s) missing. Review above and install manually."
else
    echo "========================================="
    echo " Installation complete!"
    echo "========================================="
    echo ""
    echo "Next step: sudo reboot"
    echo ""
    echo "After reboot, look for 'RDK-X5-Setup-XXXX' on your phone WiFi."
    echo ""
    echo "Reconfigure:  sudo systemctl start wifi-setup"
    echo "View logs:    sudo journalctl -u wifi-setup -f"
    echo ""
fi