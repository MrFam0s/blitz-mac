#!/bin/bash
# Package an already built, Developer ID-signed app. No install, upload or push.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/.build/Blitz Neo.app"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "ERROR: Set APPLE_SIGNING_IDENTITY to a Developer ID Application identity." >&2
    exit 1
fi

read -r VERSION BUILD_NUMBER < <(python3 - "$ROOT_DIR/package.json" "$SOURCE_APP/Contents/Info.plist" <<'PY'
import json, plistlib, re, sys
package = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'rb') as source:
    info = plistlib.load(source)
version, build = package['version'], str(package['buildNumber'])
assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid version'
assert re.fullmatch(r'[1-9]\d*', build), 'Invalid build number'
assert info['CFBundleIdentifier'] == 'org.amosystems.BlitzNeo', 'Wrong app identity'
assert info['CFBundleShortVersionString'] == version, 'Rebuild app: version mismatch'
assert info['CFBundleVersion'] == build, 'Rebuild app: build number mismatch'
print(version, build)
PY
)

codesign --verify --deep --strict "$SOURCE_APP"
for notice in LICENSE NOTICE ASC-LICENSE THIRD-PARTY-NOTICES.txt; do
    [ -s "$SOURCE_APP/Contents/Resources/$notice" ] || {
        echo "ERROR: Missing bundled license notice: $notice" >&2; exit 1;
    }
done
ARCHS="$(lipo -archs "$SOURCE_APP/Contents/MacOS/Blitz")"
case "$ARCHS" in
    arm64) ARCH_LABEL=arm64 ;;
    *) echo "ERROR: Only the verified Apple Silicon public package is supported." >&2; exit 1 ;;
esac
for executable in "$SOURCE_APP/Contents/MacOS/Blitz" \
    "$SOURCE_APP/Contents/Helpers/blitz-macos-mcp" "$SOURCE_APP/Contents/Helpers/ascd"; do
    [ "$(lipo -archs "$executable")" = "$ARCHS" ] || {
        echo "ERROR: Mixed binary architectures: $executable" >&2; exit 1;
    }
    signature="$(codesign --display --verbose=2 "$executable" 2>&1)"
    for requirement in 'Authority=Developer ID Application:' 'Timestamp=' 'runtime'; do
        case "$signature" in
            *"$requirement"*) ;;
            *) echo "ERROR: Public binary lacks $requirement: $executable" >&2; exit 1 ;;
        esac
    done
done
python3 "$ROOT_DIR/scripts/verify-macos-deployment.py" \
    --maximum "$(cat "$ROOT_DIR/config/macos-deployment-target.txt")" \
    "$SOURCE_APP/Contents/MacOS/Blitz" \
    "$SOURCE_APP/Contents/Helpers/blitz-macos-mcp" "$SOURCE_APP/Contents/Helpers/ascd"

OUTPUT_DIR="$ROOT_DIR/build/public/$VERSION-build$BUILD_NUMBER"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DMG="$OUTPUT_DIR/BlitzNeo-$VERSION-$ARCH_LABEL.dmg"
if [ -e "$OUTPUT_DMG" ]; then
    echo "ERROR: Refusing to overwrite existing release artifact: $OUTPUT_DMG" >&2
    exit 1
fi
STAGE_DIR="$(mktemp -d "$OUTPUT_DIR/.dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto "$SOURCE_APP" "$STAGE_DIR/Blitz Neo.app"
ln -s /Applications "$STAGE_DIR/Applications"
cat > "$STAGE_DIR/Read Me.txt" <<'TXT'
Blitz Neo — AmoSystems public preview

Drag Blitz Neo.app into Applications, then open it from there.
Quit an existing Blitz Neo instance before replacing the app.
Your project folders and ~/.blitz data are not part of this download.

Requires Apple Silicon and macOS 14 or later.
Xcode and suitable runtimes are needed for builds and simulators.
Use your own App Store Connect account and coding assistant.

The app provisions its native ASC and macOS MCP/CLI helpers on launch.
The optional iPhone MCP and idb tooling require separate developer setup;
this download does not run the legacy installer or download a simulator.

Documentation and source: https://github.com/MrFam0s/blitz-mac
License notices: Blitz Neo.app/Contents/Resources
TXT
codesign --verify --deep --strict "$STAGE_DIR/Blitz Neo.app"
hdiutil create -quiet -format UDZO -volname 'Blitz Neo' -srcfolder "$STAGE_DIR" "$OUTPUT_DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_DMG"
codesign --verify --strict "$OUTPUT_DMG"
printf 'Prepared: %s\nNotarize and staple before publishing; see docs/public-release.md.\n' "$OUTPUT_DMG"
