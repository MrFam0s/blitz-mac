#!/bin/bash
# Creates a proper macOS .app bundle from the SPM build.
# Signs with Developer ID so TCC grants persist across rebuilds.
set -e

CONFIG="${1:-release}"
APP_NAME="Blitz"
BUNDLE_DIR=".build/${APP_NAME}.app"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Load .env (existing env vars take precedence)
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
ENTITLEMENTS="$ROOT_DIR/scripts/Entitlements.plist"
TIMESTAMP_MODE="${CODESIGN_TIMESTAMP:-auto}"
REQUIRE_SIGNED_RELEASE="${BLITZ_REQUIRE_SIGNED_RELEASE:-0}"

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

resolve_ascd_path() {
    local candidate="${BLITZ_ASCD_PATH:-}"
    [ -n "$candidate" ] || return 1
    [ -x "$candidate" ] || return 1
    printf '%s\n' "$candidate"
}

verify_ascd_helper() {
    local helper_path="$1"
    local response

    response="$(printf '{"id":"bundle-check","method":"ping"}\n' | "$helper_path" 2>/dev/null | head -1 || true)"
    case "$response" in
        *'"id":"bundle-check"'*'"result"'*'"version":"5.15.0 (commit: b9520c3865b54c5c02f905793ac3565fc2885aee,'*)
            return 0
            ;;
    esac

    return 1
}

if [ "$CONFIG" = "debug" ] && [ "$TIMESTAMP_MODE" = "auto" ]; then
    TIMESTAMP_MODE="none"
fi

if [ -z "$SIGNING_IDENTITY" ] && [ "$REQUIRE_SIGNED_RELEASE" = "1" ]; then
    echo "ERROR: APPLE_SIGNING_IDENTITY is required for production release builds." >&2
    exit 1
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "WARNING: APPLE_SIGNING_IDENTITY not set, falling back to ad-hoc signing."
    echo "         TCC will require re-approval on every rebuild."
    SIGNING_IDENTITY="-"
fi

ANALYTICS_PLIST_KEYS=""
if [ "$CONFIG" != "debug" ]; then
    if [ -n "${BLITZ_ANALYTICS_ENDPOINT:-}" ] && [ -n "${BLITZ_ANALYTICS_TOKEN:-}" ]; then
        ANALYTICS_ENDPOINT_ESCAPED="$(xml_escape "$BLITZ_ANALYTICS_ENDPOINT")"
        ANALYTICS_TOKEN_ESCAPED="$(xml_escape "$BLITZ_ANALYTICS_TOKEN")"
        echo "Embedding analytics config for this build."
        ANALYTICS_PLIST_KEYS="
    <key>BlitzAnalyticsEndpoint</key>
    <string>$ANALYTICS_ENDPOINT_ESCAPED</string>
    <key>BlitzAnalyticsToken</key>
    <string>$ANALYTICS_TOKEN_ESCAPED</string>"
    elif [ -n "${BLITZ_ANALYTICS_ENDPOINT:-}" ] || [ -n "${BLITZ_ANALYTICS_TOKEN:-}" ]; then
        echo "WARNING: BLITZ_ANALYTICS_ENDPOINT and BLITZ_ANALYTICS_TOKEN must both be set."
        echo "         Analytics config will not be embedded in this build."
    else
        echo "Analytics disabled for this build: no BLITZ_ANALYTICS_ENDPOINT / BLITZ_ANALYTICS_TOKEN provided."
    fi
else
    echo "Analytics disabled for this build: debug builds do not embed analytics config."
fi

APP_WALL_PLIST_KEYS=""
if [ "$CONFIG" != "debug" ]; then
    if [ -n "${APPWALL_INGEST_TOKEN:-}" ]; then
        APP_WALL_TOKEN_ESCAPED="$(xml_escape "$APPWALL_INGEST_TOKEN")"
        echo "Embedding App Wall ingest token for this build."
        APP_WALL_PLIST_KEYS="
    <key>BlitzAppWallToken</key>
    <string>$APP_WALL_TOKEN_ESCAPED</string>"
    else
        echo "App Wall sync disabled for this build: no APPWALL_INGEST_TOKEN provided."
    fi
else
    echo "App Wall sync disabled for this build: debug builds do not embed App Wall ingest config."
fi

# Read version from package.json
VERSION=$(node -e "const p=JSON.parse(require('fs').readFileSync('$ROOT_DIR/package.json','utf8')); process.stdout.write(p.version)" 2>/dev/null \
  || grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
echo "Building $APP_NAME.app v$VERSION ($CONFIG)..."

# Build
# Use the same engine for both products. Xcode 27 defaults to swiftbuild,
# which additionally requires the optional Metal toolchain for SwiftTerm.
BUILD_SYSTEM_ARGS=()
if [ -n "${BLITZ_SWIFT_BUILD_SYSTEM:-}" ]; then
    BUILD_SYSTEM_ARGS=(--build-system "$BLITZ_SWIFT_BUILD_SYSTEM")
fi
if [ -n "${BLITZ_BUILD_JOBS:-}" ]; then
    if ! [[ "$BLITZ_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: BLITZ_BUILD_JOBS must be a positive integer." >&2
        exit 1
    fi
    BUILD_SYSTEM_ARGS+=(--jobs "$BLITZ_BUILD_JOBS")
fi
swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONFIG" --product Blitz
swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONFIG" --product blitz-macos-mcp

# Create .app structure
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"
mkdir -p "$BUNDLE_DIR/Contents/Helpers"

# Copy binary
cp ".build/${CONFIG}/${APP_NAME}" "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"

# Copy the standalone MCP helper that Codex launches directly over stdio.
HELPER_BINARY=".build/${CONFIG}/blitz-macos-mcp"
if [ -f "$HELPER_BINARY" ]; then
    cp "$HELPER_BINARY" "$BUNDLE_DIR/Contents/Helpers/blitz-macos-mcp"
    chmod 755 "$BUNDLE_DIR/Contents/Helpers/blitz-macos-mcp"
    echo "Copied blitz-macos-mcp helper into app bundle"
else
    echo "WARNING: blitz-macos-mcp helper was not built; MCP integration will be unavailable."
fi

ASC_HELPER_BINARY="$(resolve_ascd_path || true)"
if [ -z "$ASC_HELPER_BINARY" ]; then
    ASC_HELPER_BINARY="$(bash "$ROOT_DIR/scripts/build-asc-helper.sh")"
fi

if [ -n "$ASC_HELPER_BINARY" ]; then
    if ! verify_ascd_helper "$ASC_HELPER_BINARY"; then
        echo "ERROR: ascd helper is not compatible with Blitz:"
        echo "       $ASC_HELPER_BINARY"
        echo "       Expected ASC 5.15.0 at the pinned commit with the Blitz JSON-line protocol adapter."
        exit 1
    fi
    cp "$ASC_HELPER_BINARY" "$BUNDLE_DIR/Contents/Helpers/ascd"
    chmod 755 "$BUNDLE_DIR/Contents/Helpers/ascd"
    echo "Copied ascd helper into app bundle from $ASC_HELPER_BINARY"
else
    echo "ERROR: ascd helper not found."
    echo "       Initialize the pinned submodule and install its required Go version."
    exit 1
fi

cp "$ROOT_DIR/helpers/asc-overlay/LICENSE" "$BUNDLE_DIR/Contents/Resources/ASC-LICENSE"
cp "$ROOT_DIR/helpers/asc-overlay/README.md" "$BUNDLE_DIR/Contents/Resources/ASC-PROVENANCE.md"

# Generate app icon (.icns) from PNG
ICON_PNG="$ROOT_DIR/src/resources/blitz-icon.png"
ICON_ICNS="$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_PNG" ]; then
    if [ ! -f "$ICON_ICNS" ] || [ "$ICON_PNG" -nt "$ICON_ICNS" ]; then
        ICONSET_DIR=$(mktemp -d)/Blitz.iconset
        mkdir -p "$ICONSET_DIR"
        for size in 16 32 128 256 512; do
            sips -z $size $size "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
            double=$((size * 2))
            sips -z $double $double "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
        rm -rf "$(dirname "$ICONSET_DIR")"
        echo "Generated AppIcon.icns"
    fi
fi

# Copy SPM resource bundles into Contents/Resources/ (standard macOS location).
# NOTE: SPM's generated Bundle.module uses bundleURL (= .app root) which won't find
# bundles here. We use a custom Bundle.appResources accessor instead — see AppBundle.swift.
for bundle_dir in .build/${CONFIG}/*.bundle; do
    if [ -d "$bundle_dir" ]; then
        cp -R "$bundle_dir" "$BUNDLE_DIR/Contents/Resources/"
        echo "Copied $(basename "$bundle_dir") to Contents/Resources/"
    fi
done

# Embed Claude skills in .app bundle
SKILLS_SRC="$ROOT_DIR/src/resources/skills"
SKILLS_DST="$BUNDLE_DIR/Contents/Resources/claude-skills"
if [ -d "$SKILLS_SRC" ]; then
    rm -rf "$SKILLS_DST"
    cp -R "$SKILLS_SRC" "$SKILLS_DST"
    echo "Embedded Claude skills in .app bundle"
fi

# Embed pkg-scripts in .app for auto-updater (mirrors Tauri pattern)
PKG_SCRIPTS_SRC="$ROOT_DIR/scripts/pkg-scripts"
PKG_SCRIPTS_DST="$BUNDLE_DIR/Contents/Resources/pkg-scripts"
if [ -d "$PKG_SCRIPTS_SRC" ]; then
    mkdir -p "$PKG_SCRIPTS_DST"
    for script in "$PKG_SCRIPTS_SRC"/*; do
        [ -f "$script" ] || continue
        cp "$script" "$PKG_SCRIPTS_DST/"
        chmod 755 "$PKG_SCRIPTS_DST/$(basename "$script")"
    done
    echo "Embedded pkg-scripts in .app bundle"
fi

# Embed a reproducible maintenance package, never an unpinned npm @latest.
IPHONE_MCP_PACKAGE="${BLITZ_IPHONE_MCP_TARBALL:-}"
if [ -z "$IPHONE_MCP_PACKAGE" ]; then
    IPHONE_MCP_PACKAGE="$(bash "$ROOT_DIR/scripts/build-iphone-mcp.sh")"
fi
python3 "$ROOT_DIR/scripts/verify-iphone-mcp.py" "$IPHONE_MCP_PACKAGE"
mkdir -p "$BUNDLE_DIR/Contents/Resources/iphone-mcp"
cp "$IPHONE_MCP_PACKAGE" "$BUNDLE_DIR/Contents/Resources/iphone-mcp/"
cp "$IPHONE_MCP_PACKAGE.sha256" "$BUNDLE_DIR/Contents/Resources/iphone-mcp/"
cp "$ROOT_DIR/helpers/iphone-mcp-overlay/README.md" "$BUNDLE_DIR/Contents/Resources/iphone-mcp/PROVENANCE.md"

# Write Info.plist with correct version
cat > "$BUNDLE_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Blitz</string>
    <key>CFBundleIdentifier</key>
    <string>com.blitz.macos</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Blitz</string>
    <key>CFBundleDisplayName</key>
    <string>Blitz</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Blitz needs screen recording access to capture the iOS Simulator display.</string>
    <key>NSCameraUsageDescription</key>
    <string>Blitz needs camera access to capture physical iOS device screens via USB.</string>
$ANALYTICS_PLIST_KEYS
$APP_WALL_PLIST_KEYS
</dict>
</plist>
PLIST

# Remove stale codesign temp files from previous failed signing attempts
find "$BUNDLE_DIR" -name "*.cstemp" -delete 2>/dev/null || true

codesign_bundle_path() {
    local target="$1"

    if [ "$SIGNING_IDENTITY" = "-" ]; then
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$target"
        return
    fi

    if [ "$TIMESTAMP_MODE" = "none" ]; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$target"
        return
    fi

    if ! codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$target" 2>/dev/null; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$target"
    fi
}

# Sign nested native binaries first (inside-out — also required for ad-hoc CI bundle verification)
echo "Signing native dependencies..."
find "$BUNDLE_DIR/Contents/Resources" -type f \( -name "*.node" -o -name "*.dylib" \) 2>/dev/null | while read -r f; do
    codesign_bundle_path "$f" 2>/dev/null || true
    echo "  Signed: $f"
done
if [ -f "$BUNDLE_DIR/Contents/Helpers/blitz-macos-mcp" ]; then
    codesign_bundle_path "$BUNDLE_DIR/Contents/Helpers/blitz-macos-mcp"
    echo "  Signed: $BUNDLE_DIR/Contents/Helpers/blitz-macos-mcp"
fi
if [ -f "$BUNDLE_DIR/Contents/Helpers/ascd" ]; then
    codesign_bundle_path "$BUNDLE_DIR/Contents/Helpers/ascd"
    echo "  Signed: $BUNDLE_DIR/Contents/Helpers/ascd"
fi

# Sign the .app bundle (must be after nested signing)
if [ "$SIGNING_IDENTITY" != "-" ] && [ "$TIMESTAMP_MODE" = "auto" ]; then
    if ! codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$BUNDLE_DIR" &>/dev/null; then
        echo "Timestamp server unavailable, signing without timestamp..."
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$BUNDLE_DIR"
    fi
else
    codesign_bundle_path "$BUNDLE_DIR"
fi

echo ""
echo "Built: $BUNDLE_DIR (v$VERSION)"
echo "Signed with: $SIGNING_IDENTITY"
echo "Launch with: open $BUNDLE_DIR"
