#!/usr/bin/env python3
"""Offline regressions for the test-only upstream stdout-capture workaround."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("asc_test_overlay", Path(__file__).with_name("prepare-asc-test-overlay.py"))
OVERLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OVERLAY)


def fixture_source() -> str:
    return 'package asc\n\nimport (\n\t"bytes"\n\t"io"\n\t"os"\n\t"testing"\n)\n\n' + OVERLAY.EXPECTED_CAPTURE + '\n// unchanged downstream tests\n'


class ASCOverlayTests(unittest.TestCase):
    def test_replaces_only_expected_capture_and_unused_imports(self):
        result = OVERLAY.corrected_source(fixture_source(), OVERLAY.EXPECTED_SHARED_CAPTURE)
        self.assertIn(OVERLAY.REPLACEMENT_CAPTURE, result)
        self.assertTrue(result.endswith("// unchanged downstream tests\n"))
        self.assertNotIn('"bytes"', result)
        self.assertNotIn('"io"', result)
        self.assertNotIn('"os"', result)
        self.assertIn('"testing"', result)

    def test_changed_duplicate_or_already_fixed_helper_fails(self):
        for source in (fixture_source().replace("err = fn()", "err = changed()"),
                       fixture_source() + OVERLAY.EXPECTED_CAPTURE,
                       fixture_source().replace(OVERLAY.EXPECTED_CAPTURE, OVERLAY.REPLACEMENT_CAPTURE)):
            with self.subTest(source=source[:15]), self.assertRaises(ValueError):
                OVERLAY.corrected_source(source, OVERLAY.EXPECTED_SHARED_CAPTURE)

    def test_changed_shared_helper_or_new_import_usage_fails(self):
        with self.assertRaises(ValueError):
            OVERLAY.corrected_source(fixture_source(), OVERLAY.EXPECTED_SHARED_CAPTURE.replace("go func()", "func()"))
        with self.assertRaises(ValueError):
            OVERLAY.corrected_source(fixture_source() + "var additional = os.Stdout\n", OVERLAY.EXPECTED_SHARED_CAPTURE)

    def test_json_mapping_is_absolute_and_source_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            tests = stage / "internal/asc"
            tests.mkdir(parents=True)
            original = fixture_source()
            source = tests / "xcode_cloud_test.go"
            source.write_text(original)
            (tests / "output_test.go").write_text(OVERLAY.EXPECTED_SHARED_CAPTURE)
            path = OVERLAY.prepare_overlay(stage, root / "overlay")
            mapping = json.loads(path.read_text())["Replace"]
            self.assertEqual(list(mapping), [str(source.resolve())])
            self.assertTrue(Path(mapping[str(source.resolve())]).is_absolute())
            self.assertEqual(source.read_text(), original)
            self.assertIn(OVERLAY.REPLACEMENT_CAPTURE, Path(next(iter(mapping.values()))).read_text())
            with self.assertRaises(ValueError):
                OVERLAY.prepare_overlay(stage, stage / "overlay")


if __name__ == "__main__":
    unittest.main()
