#!/usr/bin/env python3
"""Exercise app retirement against temporary bundles, without live installation."""

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parent / "pkg-scripts/migrate-legacy-app.sh"


class LegacyAppMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="blitz-neo-migration-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.new_app = self.root / "Applications/Blitz Neo.app"
        self.old_app = self.root / "Applications/Blitz.app"
        self.backups = self.root / "user data/.blitz/backups"
        self.user_data = self.root / "user data/.blitz/settings.json"
        self.user_data.parent.mkdir(parents=True)
        self.user_data.write_text('"unchanged user settings"')
        self.make_app(self.new_app, "org.amosystems.BlitzNeo")
        self.make_app(self.old_app, "com.blitz.macos")

    def make_app(self, path, identifier):
        (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        executable = path / "Contents/MacOS/Blitz"
        executable.write_text("legacy binary fixture")
        executable.chmod(0o755)

    def migrate(self):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.new_app), str(self.old_app), str(self.backups)],
            capture_output=True, text=True,
        )

    def test_moves_only_legacy_bundle_and_keeps_user_data(self):
        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.old_app.exists())
        backups = list(self.backups.glob("*/Blitz.app/Contents/MacOS/Blitz"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "legacy binary fixture")
        self.assertTrue(self.new_app.exists())
        self.assertEqual(self.user_data.read_text(), '"unchanged user settings"')

    def test_wrong_replacement_identity_keeps_legacy_app(self):
        self.make_app(self.new_app, "org.example.Unrelated")
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertTrue(self.old_app.exists())
        self.assertFalse(self.backups.exists())

    def test_incomplete_replacement_keeps_legacy_app(self):
        (self.new_app / "Contents/MacOS/Blitz").unlink()
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertTrue(self.old_app.exists())

    def test_different_legacy_identity_is_not_touched(self):
        self.make_app(self.old_app, "org.example.Unrelated")
        self.assertEqual(self.migrate().returncode, 0)
        self.assertTrue(self.old_app.exists())
        self.assertFalse(self.backups.exists())

    def test_repeat_is_noop_and_a_new_predecessor_cannot_overwrite_backup(self):
        self.assertEqual(self.migrate().returncode, 0)
        self.assertEqual(self.migrate().returncode, 0)
        self.assertEqual(len(list(self.backups.iterdir())), 1)
        self.make_app(self.old_app, "com.blitz.macos")
        self.assertEqual(self.migrate().returncode, 0)
        self.assertEqual(len(list(self.backups.iterdir())), 2)


if __name__ == "__main__":
    unittest.main()
