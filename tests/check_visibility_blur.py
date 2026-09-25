"""Opt-in compositor regression: hidden surfaces must not blur application content.

Requires an installed Lucid shell, Hyprland, qs, grim and Pillow. Temporarily
changes only the two visibility preferences and restores them in finally.
Screenshots contain only a crop of this script's synthetic striped window.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageStat

FIXTURE = '''import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        visible: true
        title: "Lucid blur regression"
        color: "white"
        implicitWidth: 800
        implicitHeight: 700
        Repeater {
            model: 300
            Rectangle {
                required property int index
                y: index * 8
                width: 5000
                height: 8
                color: index % 2 ? "black" : "white"
            }
        }
    }
}
'''


def compositor(command):
    return json.loads(subprocess.check_output(["hyprctl", "-j", command], timeout=5))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="authorize temporary live visibility changes")
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live to run against the current desktop")
    settings = Path.home() / ".config/quickshell/lucidprefs/prefs.json"
    keys = ("barVisibility", "dockVisibility")
    original = json.loads(settings.read_text())

    def update(values):
        # Re-read so unrelated settings edited during the check survive.
        data = json.loads(settings.read_text())
        for key in keys:
            if key in values:
                data[key] = values[key]
            else:
                data.pop(key, None)
        pending = settings.with_suffix(".blur-check")
        pending.write_text(json.dumps(data, indent=2))
        os.replace(pending, settings)

    with tempfile.TemporaryDirectory(prefix="lucid-blur-regression-") as tmp:
        root = Path(tmp)
        (root / "shell.qml").write_text(FIXTURE)
        with (root / "fixture.log").open("w") as log:
            process = subprocess.Popen(["qs", "-p", str(root), "--no-color"],
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(50):
                    if any(c.get("pid") == process.pid for c in compositor("clients")):
                        break
                    if process.poll() is not None:
                        raise RuntimeError((root / "fixture.log").read_text())
                    time.sleep(0.1)
                baseline = None
                for bar, dock in [("always", "always"), ("dodge", "always"),
                                  ("auto", "always"), ("always", "dodge"), ("always", "auto")]:
                    update(dict(zip(keys, (bar, dock))))
                    time.sleep(1)
                    client = next(c for c in compositor("clients") if c.get("pid") == process.pid)
                    if min(client["size"]) < 260:
                        raise RuntimeError("Test window is too small for a clean sample")
                    x, y = client["at"]
                    screenshot = root / "sample.png"
                    subprocess.run(["grim", "-g", f"{x + 80},{y + 80} 160x160", str(screenshot)],
                                   check=True, timeout=5)
                    with Image.open(screenshot) as image:
                        contrast = ImageStat.Stat(image.convert("L")).stddev[0]
                    if baseline is None:
                        baseline = contrast
                        assert baseline > 100, "Baseline is not sharp; remove overlays and retry"
                    assert contrast >= baseline * 0.95, f"{bar}/{dock} blurs app content: {contrast:.2f} vs {baseline:.2f}"
                    print(f"PASS bar={bar}, dock={dock}: contrast {contrast:.2f} (baseline {baseline:.2f})")
            finally:
                try:
                    update(original)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
