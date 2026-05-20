#!/usr/bin/env python3
"""LED status indication via sysfs for RDK X5 WiFi configuration feedback."""

import os
import time
import threading

LED_BASE = "/sys/class/leds"


def _find_led():
    """Auto-discover an available user LED."""
    if not os.path.exists(LED_BASE):
        return None
    preferred = ["user-led0", "status", "ACT", "led0", "led1", "led2"]
    entries = os.listdir(LED_BASE)
    for name in preferred:
        if name in entries:
            return os.path.join(LED_BASE, name)
    # Fallback to first available LED
    for entry in entries:
        if entry not in ("mmc0", "mmc1", "mmc2"):
            return os.path.join(LED_BASE, entry)
    return None


class StatusLED:
    """Controls LED patterns for WiFi configuration status."""

    def __init__(self):
        self._led_path = _find_led()
        self._lock = threading.Lock()
        self._pattern = None  # None, "slow", "fast", "error", "solid"
        self._running = True
        self._thread = threading.Thread(target=self._blink_loop, daemon=True)

    def start(self):
        if self._led_path and self._is_writable():
            self._thread.start()

    def stop(self):
        self._running = False
        self._pattern = None
        if self._led_path:
            try:
                self._write_brightness(0)
            except Exception:
                pass

    def set_pattern(self, pattern):
        with self._lock:
            self._pattern = pattern

    def ap_waiting(self):
        self.set_pattern("slow")

    def connecting(self):
        self.set_pattern("fast")

    def success(self):
        self.set_pattern("solid")

    def error(self):
        self.set_pattern("error")

    def _is_writable(self):
        trigger = os.path.join(self._led_path, "trigger")
        return os.access(trigger, os.W_OK)

    def _write_brightness(self, value):
        brightness = os.path.join(self._led_path, "brightness")
        with open(brightness, "w") as f:
            f.write(str(value))

    def _set_trigger(self, mode):
        trigger = os.path.join(self._led_path, "trigger")
        with open(trigger, "w") as f:
            f.write(mode)

    def _blink_loop(self):
        # Set to gpio/gpio mode for manual control
        try:
            self._set_trigger("none")
        except Exception:
            pass

        error_step = 0
        error_timer = 0

        while self._running:
            with self._lock:
                pattern = self._pattern

            if pattern is None:
                time.sleep(0.1)
                continue

            if pattern == "slow":
                self._write_brightness(1)
                time.sleep(0.5)
                self._write_brightness(0)
                time.sleep(0.5)

            elif pattern == "fast":
                self._write_brightness(1)
                time.sleep(0.125)
                self._write_brightness(0)
                time.sleep(0.125)

            elif pattern == "solid":
                self._write_brightness(1)
                time.sleep(5)
                self._write_brightness(0)
                with self._lock:
                    self._pattern = None

            elif pattern == "error":
                # 3 rapid blinks then 2s pause
                for _ in range(3):
                    if not self._running:
                        return
                    self._write_brightness(1)
                    time.sleep(0.1)
                    self._write_brightness(0)
                    time.sleep(0.1)
                time.sleep(2)


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    led = StatusLED()
    led.start()
    if cmd == "slow":
        led.ap_waiting()
    elif cmd == "fast":
        led.connecting()
    elif cmd == "success":
        led.success()
    elif cmd == "error":
        led.error()
    elif cmd == "stop":
        led.stop()
        sys.exit(0)
    else:
        print(f"Usage: {sys.argv[0]} slow|fast|success|error|stop", file=sys.stderr)
        led.stop()
        sys.exit(1)
    # Keep running to allow LED thread to blink
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        led.stop()