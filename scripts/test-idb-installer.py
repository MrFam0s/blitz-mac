#!/usr/bin/env python3
"""Offline checks: a failed download must not replace an existing companion."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parent / "pkg-scripts/install-idb-companion.sh"
PIN = "1.7.6 f81e5ff131c8c91fb6927cb445a7267a4e80c543e51e4b26ebcaa00eff4e3c1f"


class CompanionInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="blitz-idb-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.destination = self.root / "idb-companion"
        self.destination.mkdir()
        (self.destination / "old-installation").write_text("preserve me")
        self.stub("uname", "echo arm64")
        self.stub("sw_vers", "echo 27.0")
        self.stub("xcodebuild", "echo 'Xcode 27.0'")
        self.stub("curl", 'while [ "$1" != "-o" ]; do shift; done; shift; echo invalid > "$1"')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_installer(self):
        return subprocess.run(["/bin/bash", str(SCRIPT), str(self.destination)],
                              env={"HOME": str(self.root), "PATH": f"{self.bin}:/usr/bin:/bin"},
                              text=True, capture_output=True)

    def test_checksum_failure_preserves_previous_installation(self):
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "old-installation").read_text(), "preserve me")
        self.assertEqual(list(self.root.glob("idb-companion.staging.*")), [])
        self.assertEqual(list(self.root.glob("idb-companion.backup.*")), [])

    def test_current_install_does_not_download(self):
        self.stub("curl", "exit 99")
        (self.destination / ".blitz-version").write_text(PIN + "\n")
        (self.destination / "bin").mkdir()
        executable = self.destination / "bin/idb_companion"
        executable.write_text("#!/bin/bash\nexit 0\n")
        executable.chmod(0o755)
        (self.destination / "Resources").mkdir()
        (self.destination / "Resources/libShimulator-iOS.dylib").touch()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already installed", result.stdout)

    def test_unsupported_host_keeps_legacy_installation(self):
        self.stub("uname", "echo x86_64")
        self.stub("curl", "exit 99")
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / "old-installation").exists())
        self.assertIn("keeping legacy", result.stdout)


if __name__ == "__main__":
    unittest.main()
