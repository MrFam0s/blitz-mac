#!/usr/bin/env python3
"""Create a test-only Go overlay for ASC 6.6.1's synchronous stdout capture.

The pinned source and production build remain untouched. Stop on upstream drift
so a later ASC update must explicitly remove or re-review this workaround.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile


EXPECTED_CAPTURE = '''func captureXcodeCloudStdout(t *testing.T, fn func() error) string {
\tt.Helper()

\torig := os.Stdout
\tr, w, err := os.Pipe()
\tif err != nil {
\t\tt.Fatalf("pipe error: %v", err)
\t}
\tos.Stdout = w

\terr = fn()

\tif closeErr := w.Close(); closeErr != nil {
\t\tt.Fatalf("close error: %v", closeErr)
\t}
\tos.Stdout = orig

\tvar buf bytes.Buffer
\tif _, readErr := io.Copy(&buf, r); readErr != nil {
\t\tt.Fatalf("read error: %v", readErr)
\t}
\tif err != nil {
\t\tt.Fatalf("function error: %v", err)
\t}

\treturn buf.String()
}
'''

EXPECTED_SHARED_CAPTURE = '''func captureStdout(t *testing.T, fn func() error) string {
\tt.Helper()

\torig := os.Stdout
\tr, w, err := os.Pipe()
\tif err != nil {
\t\tt.Fatalf("pipe error: %v", err)
\t}
\tdefer func() {
\t\tos.Stdout = orig
\t\t_ = w.Close()
\t\t_ = r.Close()
\t}()

\tvar buf bytes.Buffer
\treadDone := make(chan error, 1)
\tgo func() {
\t\t_, readErr := io.Copy(&buf, r)
\t\treadDone <- readErr
\t}()
\tos.Stdout = w

\terr = fn()

\tif closeErr := w.Close(); closeErr != nil {
\t\tt.Fatalf("close error: %v", closeErr)
\t}
\tos.Stdout = orig

\tif readErr := <-readDone; readErr != nil {
\t\tt.Fatalf("read error: %v", readErr)
\t}
\tif err != nil {
\t\tt.Fatalf("function error: %v", err)
\t}

\treturn buf.String()
}
'''

REPLACEMENT_CAPTURE = '''func captureXcodeCloudStdout(t *testing.T, fn func() error) string {
\tt.Helper()
\treturn captureStdout(t, fn)
}
'''


def corrected_source(source: str, shared_source: str) -> str:
    if source.count(EXPECTED_CAPTURE) != 1 or source.count("func captureXcodeCloudStdout(") != 1:
        raise ValueError("ASC Xcode Cloud stdout test changed; review or remove the test-only overlay")
    if shared_source.count(EXPECTED_SHARED_CAPTURE) != 1 or shared_source.count("func captureStdout(") != 1:
        raise ValueError("ASC shared stdout test helper changed; re-review concurrent capture before testing")
    corrected = source.replace(EXPECTED_CAPTURE, REPLACEMENT_CAPTURE, 1)
    for package in ("bytes", "io", "os"):
        import_line = f'\t"{package}"\n'
        if corrected.count(import_line) != 1 or re.search(rf"\b{package}\.", corrected):
            raise ValueError(f"ASC test imports/usages changed ({package}); review the test-only overlay")
        corrected = corrected.replace(import_line, "", 1)
    return corrected


def atomic_write(path: Path, contents: str) -> None:
    if path.is_symlink():
        raise ValueError("Refusing a symlink at the test overlay output path")
    descriptor, temporary = tempfile.mkstemp(prefix=".asc-test-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as output:
            output.write(contents)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepare_overlay(stage_dir: Path, output_dir: Path) -> Path:
    stage = stage_dir.resolve(strict=True)
    source = stage / "internal/asc/xcode_cloud_test.go"
    shared = stage / "internal/asc/output_test.go"
    if source.is_symlink() or shared.is_symlink():
        raise ValueError("Expected ordinary ASC test source files")
    corrected = corrected_source(source.read_bytes().decode("utf-8"), shared.read_bytes().decode("utf-8"))
    if output_dir.is_symlink():
        raise ValueError("Refusing a symlink as the test overlay directory")
    output = output_dir.resolve()
    if output == stage or stage in output.parents:
        raise ValueError("Test overlay output must be outside the staged ASC source")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    replacement = output / "xcode_cloud_test.go"
    overlay = output / "asc-test-overlay.json"
    atomic_write(replacement, corrected)
    atomic_write(overlay, json.dumps({"Replace": {str(source): str(replacement)}}, indent=2) + "\n")
    return overlay


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage-dir", required=True, type=Path, help="Existing staged ASC source (read only)")
    parser.add_argument("--output-dir", required=True, type=Path, help="Temporary output directory outside the staged source")
    args = parser.parse_args()
    try:
        print(prepare_overlay(args.stage_dir, args.output_dir))
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"ASC test overlay: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
