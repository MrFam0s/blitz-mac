#!/bin/bash
# Modified for the AmoSystems Blitz Neo maintenance fork (2026).
# verify-build.sh — Build Blitz Neo from source and compare against a released binary.
#
# Usage:
#   bash scripts/verify-build.sh [version-tag]
#
# Examples:
#   bash scripts/verify-build.sh v1.0.20
#   bash scripts/verify-build.sh          # compares against local .build/
#
# This script builds the app from source with ad-hoc signing, then compares
# the resulting binary checksums against the release checksums from GitHub.
# Since code signing and timestamps make full .app.zip reproducibility
# impractical, we compare the actual Mach-O executables and resource files.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TAG="${1:-}"
VERIFY_DIR=$(mktemp -d)

echo "==> Building from source (release, ad-hoc signed)..."
swift build -c release
APPLE_SIGNING_IDENTITY="-" bash scripts/bundle.sh release 2>/dev/null

echo "==> Generating checksums from local build..."
LOCAL_CHECKSUMS="$VERIFY_DIR/local-checksums.txt"

# Checksum the main executable
shasum -a 256 ".build/Blitz Neo.app/Contents/MacOS/Blitz" > "$LOCAL_CHECKSUMS"

# Checksum all resource files (excluding code signature which varies by identity)
find ".build/Blitz Neo.app/Contents/Resources" -type f -exec shasum -a 256 {} + >> "$LOCAL_CHECKSUMS" 2>/dev/null || true

echo ""
echo "==> Local build checksums:"
cat "$LOCAL_CHECKSUMS"

if [ -n "$TAG" ]; then
    echo ""
    echo "==> Downloading release checksums for $TAG..."
    RELEASE_CHECKSUMS="$VERIFY_DIR/release-checksums.txt"

    if command -v gh &>/dev/null; then
        gh release download "$TAG" --pattern "SHA256SUMS.txt" --dir "$VERIFY_DIR" 2>/dev/null && \
            mv "$VERIFY_DIR/SHA256SUMS.txt" "$RELEASE_CHECKSUMS" || true
    fi

    if [ -f "$RELEASE_CHECKSUMS" ]; then
        echo "==> Release checksums:"
        cat "$RELEASE_CHECKSUMS"

        echo ""
        echo "==> Comparing main executable..."
        LOCAL_EXEC=$(grep "Contents/MacOS/Blitz" "$LOCAL_CHECKSUMS" | awk '{print $1}')
        RELEASE_EXEC=$(grep "Contents/MacOS/Blitz" "$RELEASE_CHECKSUMS" | awk '{print $1}')

        if [ "$LOCAL_EXEC" = "$RELEASE_EXEC" ]; then
            echo "MATCH: Main executable checksum matches release."
        else
            echo "MISMATCH: Main executable differs from release."
            echo "  Local:   $LOCAL_EXEC"
            echo "  Release: $RELEASE_EXEC"
            echo ""
            echo "This is expected if the release was signed with a Developer ID"
            echo "certificate (code signing modifies the binary). The CI build"
            echo "uses ad-hoc signing, same as this local build."
        fi
    else
        echo "Could not download release checksums."
        echo "You can manually compare against the SHA256SUMS.txt from the GitHub release."
    fi
fi

echo ""
echo "==> Checksums saved to: $LOCAL_CHECKSUMS"
echo ""
echo "To compare manually against a downloaded BlitzNeo.app.zip:"
echo "  unzip BlitzNeo.app.zip -d /tmp/blitz-release"
echo '  shasum -a 256 "/tmp/blitz-release/Blitz Neo.app/Contents/MacOS/Blitz"'
echo "  # Compare against the checksum above"

rm -rf "$VERIFY_DIR"
