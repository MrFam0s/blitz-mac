#!/usr/bin/env python3
"""Reject native release components newer than the app's declared minimum OS."""
import argparse
import re
import subprocess


def version_tuple(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid macOS deployment version")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def verify_output(output, maximum):
    # vtool emits one LC_BUILD_VERSION per slice of a universal binary.
    versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", output, re.M)
    # Older Mach-O objects may use LC_VERSION_MIN_MACOSX instead.
    versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+){0,2})", output)
    if not versions:
        raise ValueError("No macOS deployment target found in native component")
    limit = version_tuple(maximum)
    if any(version_tuple(version) > limit for version in versions):
        raise ValueError("Native component requires macOS {} but the app declares {}".format(
            ", ".join(sorted(set(versions))), maximum))
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--maximum", required=True)
    parser.add_argument("binaries", nargs="+")
    args = parser.parse_args()
    for binary in args.binaries:
        result = subprocess.run(["xcrun", "vtool", "-show-build", binary],
                                check=True, text=True, capture_output=True)
        verify_output(result.stdout, args.maximum)
    print("Native deployment targets verified: macOS {} or earlier".format(args.maximum))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("Deployment verification failed: " + str(error))
