#!/bin/bash
# Modified for the AmoSystems Blitz Neo maintenance fork (2026).
# Compile an opaque, full-bleed macOS icon separately from the in-app artwork.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Pass the bundle Resources directory}"
PARTIAL_PLIST="${2:?Pass the generated icon metadata path}"
SOURCE_IMAGE="$ROOT_DIR/branding/AppIcon.png"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/blitz-neo-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

CATALOG="$WORK_DIR/AppIcon.xcassets"
ICON_SET="$CATALOG/AppIcon.appiconset"
mkdir -p "$ICON_SET" "$OUTPUT_DIR" "$(dirname "$PARTIAL_PLIST")"
printf '{"info":{"author":"xcode","version":1}}\n' > "$CATALOG/Contents.json"

# macOS asset catalogs require every representation. Keep original artwork
# unmodified; these are deterministic build-time downscales for the compiler.
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        sips -z "$pixels" "$pixels" "$SOURCE_IMAGE" \
            --out "$ICON_SET/icon_${size}x${size}@${scale}x.png" >/dev/null
    done
done

python3 - "$ICON_SET/Contents.json" <<'PY'
import json, sys
images = [
    {"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x",
     "filename": f"icon_{size}x{size}@{scale}x.png"}
    for size in (16, 32, 128, 256, 512) for scale in (1, 2)
]
with open(sys.argv[1], "w") as output:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, output, indent=2)
    output.write("\n")
PY

xcrun actool "$CATALOG" \
    --compile "$OUTPUT_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$PARTIAL_PLIST" \
    --output-format human-readable-text --warnings --notices

test -s "$OUTPUT_DIR/Assets.car"
test -s "$OUTPUT_DIR/AppIcon.icns"
test -s "$PARTIAL_PLIST"
