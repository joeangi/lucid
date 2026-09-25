"""Exercise the real Prefs JsonAdapter using an isolated HOME and no surfaces."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("qs"), "Quickshell is required")
class VisibilityMigration(unittest.TestCase):
    def run_fixture(self, original, expected):
        with tempfile.TemporaryDirectory(prefix="lucid-visibility-prefs-") as tmp:
            root = Path(tmp)
            home = root / "home"
            settings = home / ".config/quickshell/lucidprefs/prefs.json"
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps(original))
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            for name in ("Prefs.qml", "VisibilityLogic.js"):
                shutil.copy2(REPO / name, root / name)
            (root / "shell.qml").write_text('''import QtQuick
import Quickshell
import qs
ShellRoot {
    Component.onCompleted: { void Prefs.loaded; }
    Timer {
        interval: 400
        running: true
        onTriggered: {
            console.log("MODE", Prefs.dockVisibilityMode, Prefs.barVisibilityMode);
            Qt.quit();
        }
    }
}
''')
            env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                       XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(root / "cache"),
                       QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software")
            for _ in range(2):  # reloading must retain the migrated choice
                result = subprocess.run(["qs", "-p", str(root), "--no-color"], env=env,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("MODE " + expected + " always", result.stdout)
                self.assertNotIn("TypeError", result.stdout)
                self.assertNotIn("ReferenceError", result.stdout)
                saved = json.loads(settings.read_text())
                self.assertEqual(saved["dockVisibility"], expected)
                self.assertEqual(saved["dockIconSize"], 53)

    def test_old_auto_hide_enabled(self):
        self.run_fixture({"dockAutoHide": True, "dockIconSize": 53}, "auto")

    def test_old_auto_hide_disabled(self):
        self.run_fixture({"dockAutoHide": False, "dockIconSize": 53}, "always")

    def test_new_choice_wins_over_legacy_boolean(self):
        self.run_fixture({"dockAutoHide": True, "dockVisibility": "dodge", "dockIconSize": 53}, "dodge")


if __name__ == "__main__":
    unittest.main()
