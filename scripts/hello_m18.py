"""M18 smoke test: draw a numbered icon on each LCD key, log key events,
and swap a key's icon while it is held down.

Usage: .venv/bin/python scripts/hello_m18.py [seconds]   (default: run until Ctrl+C)
"""

import os
import sys
import tempfile
import time

from PIL import Image, ImageDraw, ImageFont

import m18_patch  # noqa: F401  (fixes M18 row-swapped key events)
from StreamDock.DeviceManager import DeviceManager
from StreamDock.InputTypes import EventType

# The SDK writes temporary JPEGs to the current directory, so keep them out of the project.
WORK_DIR = tempfile.mkdtemp(prefix="streamdock-")
os.chdir(WORK_DIR)

FONT = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 56)

# Round keys under the screen have no LCD; light the RGB strip while one is held.
ROUND_KEY_COLORS = {16: (255, 0, 0), 17: (0, 255, 0), 18: (0, 0, 255)}


def make_icon(label, bg, fg="white"):
    path = os.path.join(WORK_DIR, f"{label}_{bg}.png")
    if not os.path.exists(path):
        img = Image.new("RGB", (126, 126), bg)
        ImageDraw.Draw(img).text((63, 63), label, font=FONT, fill=fg, anchor="mm")
        img.save(path)
    return path


def main():
    duration = float(sys.argv[1]) if len(sys.argv) > 1 else None

    manager = DeviceManager()
    devices = manager.enumerate()
    if not devices:
        print("No Stream Dock found")
        return 1

    device = devices[0]
    if not device.open():
        print(f"Failed to open {device.path}")
        return 1
    device.init()
    print(f"{type(device).__name__}  fw={device.firmware_version}  sn={device.serial_number}", flush=True)

    lcd_keys = range(1, device.KEY_COUNT + 1)
    device.set_brightness(80)
    device.set_led_brightness(100)
    device.set_led_color(0, 0, 0)
    device.clearAllIcon()
    for key in lcd_keys:
        device.set_key_image(key, make_icon(str(key), "#1f3a5f"))
    device.refresh()

    def on_key(dev, event):
        if event.event_type != EventType.BUTTON:
            print(f"event {event.event_type}", flush=True)
            return
        key = event.key.value
        pressed = event.state == 1
        print(f"key {key:>2} {'down' if pressed else 'up'}", flush=True)
        if key in lcd_keys:
            dev.set_key_image(key, make_icon(str(key), "#d9822b" if pressed else "#1f3a5f"))
            dev.refresh()
        elif key in ROUND_KEY_COLORS:
            dev.set_led_color(*(ROUND_KEY_COLORS[key] if pressed else (0, 0, 0)))

    device.set_key_callback(on_key)
    print("Ready - press keys (Ctrl+C to quit)", flush=True)

    try:
        start = time.time()
        while duration is None or time.time() - start < duration:
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        device.set_key_callback(None)
        device.reset_led_effect()
        time.sleep(0.1)
        device.close()
        print("closed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
