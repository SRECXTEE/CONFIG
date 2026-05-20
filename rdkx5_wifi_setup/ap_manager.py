#!/usr/bin/env python3
"""AP mode lifecycle management for RDK X5 WiFi configuration."""

import subprocess
import os
import re
import time

AP_IP = "192.168.4.1"
AP_SUBNET = "24"
FLASK_PORT = 5000
TMP_DIR = "/tmp/wifi-config"


def _render_template(template_path, output_path, variables):
    with open(template_path) as f:
        content = f.read()
    for key, value in variables.items():
        content = content.replace("{{ " + key + " }}", str(value))
        content = content.replace("{{" + key + "}}", str(value))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        f.write(content)


def _run(*args, check=False, timeout=15):
    return subprocess.run(args, capture_output=True, text=True, check=check, timeout=timeout)


def _get_wifi_iface():
    """Detect the first available WiFi interface."""
    result = _run("nmcli", "-t", "-f", "DEVICE,TYPE", "device", "status")
    for line in result.stdout.strip().split("\n"):
        if ":" in line:
            dev, dtype = line.split(":", 1)
            if dtype == "wifi":
                return dev
    # Fallback: try iwconfig
    result = _run("iwconfig")
    for line in result.stdout.split("\n"):
        if "IEEE 802.11" in line or "ESSID" in line:
            return line.split()[0]
    return None


def _get_mac_suffix(iface):
    """Get the last 4 chars of MAC address for unique SSID."""
    try:
        mac_path = f"/sys/class/net/{iface}/address"
        with open(mac_path) as f:
            mac = f.read().strip().replace(":", "").upper()
        return mac[-4:]
    except Exception:
        return "0000"


def start_ap(config_dir="/opt/wifi-config"):
    """Start AP mode: hostapd + dnsmasq + iptables redirect."""
    os.makedirs(TMP_DIR, exist_ok=True)

    iface = _get_wifi_iface()
    if not iface:
        raise RuntimeError("No WiFi interface found")

    mac_suffix = _get_mac_suffix(iface)
    ssid = f"RDK-X5-Setup-{mac_suffix}"

    # Unmanage from NetworkManager
    _run("nmcli", "dev", "set", iface, "managed", "no")

    # Bring interface down, set static IP, bring up
    _run("ip", "link", "set", iface, "down", check=True)
    _run("ip", "addr", "flush", "dev", iface)
    _run("ip", "addr", "add", f"{AP_IP}/{AP_SUBNET}", "dev", iface, check=True)
    _run("ip", "link", "set", iface, "up", check=True)
    time.sleep(0.5)

    # Render and start hostapd
    _render_template(
        os.path.join(config_dir, "hostapd.conf"),
        os.path.join(TMP_DIR, "hostapd.conf"),
        {"interface": iface, "ssid": ssid, "channel": "6"},
    )
    hostapd_proc = subprocess.Popen(
        ["hostapd", os.path.join(TMP_DIR, "hostapd.conf")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(1)
    if hostapd_proc.poll() is not None:
        raise RuntimeError("hostapd failed to start")

    # Render and start dnsmasq
    _render_template(
        os.path.join(config_dir, "dnsmasq.conf"),
        os.path.join(TMP_DIR, "dnsmasq.conf"),
        {"interface": iface},
    )
    dnsmasq_proc = subprocess.Popen(
        ["dnsmasq", "--conf-file=" + os.path.join(TMP_DIR, "dnsmasq.conf")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(0.5)

    # iptables: redirect port 80 -> Flask port, block forwarding
    _run("iptables", "-t", "nat", "-A", "PREROUTING",
         "-i", iface, "-p", "tcp", "--dport", "80",
         "-j", "REDIRECT", "--to-port", str(FLASK_PORT))
    _run("iptables", "-A", "FORWARD", "-i", iface, "-j", "DROP")

    # Save PIDs for cleanup
    with open(os.path.join(TMP_DIR, "hostapd.pid"), "w") as f:
        f.write(str(hostapd_proc.pid))
    with open(os.path.join(TMP_DIR, "dnsmasq.pid"), "w") as f:
        f.write(str(dnsmasq_proc.pid))
    with open(os.path.join(TMP_DIR, "iface"), "w") as f:
        f.write(iface)
    with open(os.path.join(TMP_DIR, "state.json"), "w") as f:
        f.write('{"ssid":"' + ssid + '","iface":"' + iface + '"}')

    return True


def stop_ap(config_dir="/opt/wifi-config"):
    """Stop AP mode and restore network state."""
    iface_file = os.path.join(TMP_DIR, "iface")
    hostapd_pid_file = os.path.join(TMP_DIR, "hostapd.pid")
    dnsmasq_pid_file = os.path.join(TMP_DIR, "dnsmasq.pid")

    iface = None
    if os.path.exists(iface_file):
        with open(iface_file) as f:
            iface = f.read().strip()

    # Kill processes
    for pid_file in [hostapd_pid_file, dnsmasq_pid_file]:
        if os.path.exists(pid_file):
            with open(pid_file) as f:
                try:
                    pid = int(f.read().strip())
                    os.kill(pid, 15)  # SIGTERM
                except (ValueError, ProcessLookupError):
                    pass

    time.sleep(0.5)

    # Remove iptables rules
    if iface:
        _run("iptables", "-t", "nat", "-D", "PREROUTING",
             "-i", iface, "-p", "tcp", "--dport", "80",
             "-j", "REDIRECT", "--to-port", str(FLASK_PORT))
        _run("iptables", "-D", "FORWARD", "-i", iface, "-j", "DROP")

    # Remove static IP and restore NetworkManager
    if iface:
        _run("ip", "addr", "flush", "dev", iface)
        _run("ip", "link", "set", iface, "down")
        _run("nmcli", "dev", "set", iface, "managed", "yes")
        _run("ip", "link", "set", iface, "up")

    # Cleanup temp files
    for f in [hostapd_pid_file, dnsmasq_pid_file, iface_file,
              os.path.join(TMP_DIR, "hostapd.conf"),
              os.path.join(TMP_DIR, "dnsmasq.conf"),
              os.path.join(TMP_DIR, "state.json")]:
        if os.path.exists(f):
            os.remove(f)


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    config_dir = sys.argv[2] if len(sys.argv) > 2 else "/opt/wifi-config"
    if cmd == "start":
        start_ap(config_dir)
    elif cmd == "stop":
        stop_ap(config_dir)
    else:
        print(f"Usage: {sys.argv[0]} start|stop [config_dir]", file=sys.stderr)
        sys.exit(1)