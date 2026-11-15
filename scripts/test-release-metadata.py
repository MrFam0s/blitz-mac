#!/usr/bin/env python3
"""Offline regression checks for release deployment and license completeness."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deployment = load("verify-macos-deployment")
notices = load("collect-binary-notices")


class ReleaseMetadataTests(unittest.TestCase):
    def test_accepts_supported_native_minimum(self):
        self.assertEqual(deployment.verify_output(" cmd LC_BUILD_VERSION\n minos 14.0\n sdk 27.2\n", "14.0"), ["14.0"])

    def test_rejects_host_sdk_minimum_leaking_into_helper(self):
        with self.assertRaises(ValueError):
            deployment.verify_output(" minos 27.2\n sdk 27.2\n", "14.0")

    def test_checks_every_architecture(self):
        with self.assertRaises(ValueError):
            deployment.verify_output("arm64:\n minos 14.0\nx86_64:\n minos 15.0\n", "14.0")

    def test_accepts_legacy_version_command(self):
        self.assertEqual(deployment.verify_output(" cmd LC_VERSION_MIN_MACOSX\n cmdsize 16\n version 13.0\n sdk 14.0\n", "14.0"), ["13.0"])

    def test_rejects_missing_native_metadata(self):
        with self.assertRaises(ValueError):
            deployment.verify_output("not a Mach-O file", "14.0")

    def test_links_only_binary_dependencies(self):
        output = "ascd: go1.27.3\n mod example.com/main (devel)\n dep example.com/A v1.2.3 hash\n dep example.com/B/v2 v2.0.1 hash\n build GOARCH=arm64"
        self.assertEqual(notices.linked_modules(output), [("example.com/A", "v1.2.3"), ("example.com/B/v2", "v2.0.1")])
        self.assertEqual(notices.module_escape("example.com/A"), "example.com/!a")

    def test_rejects_local_module_replacement(self):
        with self.assertRaises(ValueError):
            notices.linked_modules("dep example.com/a v1.0.0 hash\n=> ../private-source (devel)")

    def test_rejects_unsafe_module_path(self):
        with self.assertRaises(ValueError):
            notices.linked_modules("dep example.com/../a v1.0.0 hash")

    def test_requires_actual_license_not_just_attribution(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "NOTICE").write_text("Attribution")
            with self.assertRaises(ValueError):
                notices.source_notices(directory)
            (directory / "LICENSE").write_text("License text")
            (directory / "credentials.json").write_text("Not a license")
            self.assertEqual(notices.source_notices(directory), [("LICENSE", "License text"), ("NOTICE", "Attribution")])


if __name__ == "__main__":
    unittest.main()
