#!/usr/bin/env python3
"""Collect offline source notices for the exact dependencies linked into ASC.

No dependency is downloaded. Missing cached source or license text blocks the
release instead of silently producing an incomplete notice file.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess


def go_output(go, *arguments, environment=None):
    return subprocess.check_output([go, *arguments], text=True, env=environment).strip()


def linked_modules(build_info):
    modules = []
    for line in build_info.splitlines():
        fields = line.split()
        if fields[:1] == ["=>"]:
            raise ValueError("Replaced Go modules require an explicit source-notice mapping")
        if fields[:1] != ["dep"]:
            continue
        if len(fields) < 3:
            raise ValueError("Incomplete Go dependency metadata")
        module, version = fields[1:3]
        if not re.fullmatch(r"[A-Za-z0-9._~+/-]+", module) or any(
                part in ["", ".", ".."] for part in module.split("/")):
            raise ValueError("Unsafe Go module name")
        if not re.fullmatch(r"v[0-9][A-Za-z0-9.+-]*", version):
            raise ValueError("Go dependency has no immutable module version")
        modules.append((module, version))
    if not modules:
        raise ValueError("No linked Go dependency metadata found")
    return sorted(set(modules))


def module_escape(value):
    # Go's module-cache path encoding for uppercase characters.
    return "".join("!" + char.lower() if char.isupper() else char for char in value)


def source_notices(directory):
    if not directory.is_dir():
        raise ValueError("Dependency source is absent from the local build cache")
    files = sorted(path for path in directory.iterdir() if path.is_file() and
                   re.match(r"^(LICENSE|LICENCE|COPYING|NOTICE|PATENTS)([.-]|$)", path.name, re.I))
    if not any(re.match(r"^(LICENSE|LICENCE|COPYING)([.-]|$)", path.name, re.I) for path in files):
        raise ValueError("Dependency source has no root license file")
    return [(path.name, path.read_text(encoding="utf-8")) for path in files]


def collect(root, helper, go):
    build_info = go_output(go, "version", "-m", str(helper))
    toolchain = build_info.splitlines()[0].rsplit(": ", 1)[-1]
    if not re.fullmatch(r"go[0-9]+\.[0-9]+\.[0-9]+", toolchain):
        raise ValueError("Helper has no stable Go toolchain version")
    # A go.mod may have selected a newer cached toolchain during compilation.
    # Select that exact version for its notices, without allowing a download.
    environment = dict(os.environ, GOTOOLCHAIN=toolchain, GOPROXY="off")
    cache = Path(go_output(go, "env", "GOMODCACHE", environment=environment))
    go_root = Path(go_output(go, "env", "GOROOT", environment=environment))
    # Runtime notice must match the compiler that supplied the linked stdlib.
    if go_output(go, "env", "GOVERSION", environment=environment) != toolchain:
        raise ValueError("Notice collection must use the Go version that built the helper")
    swift_term = root / ".build/checkouts/SwiftTerm"
    swift_revision = subprocess.check_output(
        ["git", "-C", str(swift_term), "rev-parse", "HEAD"], text=True).strip()
    entries = [
        ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm/tree/" + swift_revision,
         source_notices(swift_term)),
        ("Go runtime and standard library " + toolchain, "https://go.dev/",
         source_notices(go_root)),
    ]
    for module, version in linked_modules(build_info):
        directory = cache / (module_escape(module) + "@" + module_escape(version))
        try:
            notices = source_notices(directory)
        except ValueError as error:
            raise ValueError("{} {}: {}".format(module, version, error)) from error
        entries.append((module + " " + version, "https://pkg.go.dev/" + module + "@" + version, notices))
    output = ["Blitz Neo — bundled third-party notices\n",
              "Blitz, ASC and the bundled iPhone MCP also retain their own LICENSE and provenance files.\n",
              "The sections below reproduce notices from the build's SwiftTerm source, Go toolchain and linked Go modules.\n"]
    for name, source, notices in entries:
        output.extend(["\n" + "=" * 78 + "\n", name + "\n", "Source: " + source + "\n"])
        for filename, content in notices:
            output.extend(["\n--- " + filename + " ---\n", content.rstrip() + "\n"])
    return "".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--go", default=os.environ.get("GO", "go"))
    args = parser.parse_args()
    result = collect(args.root, args.helper, args.go)
    args.output.write_text(result, encoding="utf-8")
    print("Collected SwiftTerm, Go runtime and linked Go module notices")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("Notice collection failed: " + str(error))
