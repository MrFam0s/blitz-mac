#!/bin/bash
# Official, checksummed IDB companion for modern Apple Silicon/Xcode installs.
# Keep the flat release tree: Resources/ must remain beside idb_companion.
set -euo pipefail

DESTINATION="${1:?Pass the Blitz idb-companion directory}"
VERSION=1.7.6
SHA256=f81e5ff131c8c91fb6927cb445a7267a4e80c543e51e4b26ebcaa00eff4e3c1f
URL="https://github.com/facebook/idb/releases/download/v${VERSION}/idb-companion.macos-arm64.tar.gz"

# Upstream currently ships this release for arm64, macOS 15+, Xcode 26+.
# Preserve the existing legacy installation on unsupported hosts.
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | awk '/^Xcode / {split($2,v,"."); print v[1]}')
if [ "$(uname -m)" != arm64 ] || [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ] ||
   [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
    echo "IDB ${VERSION}: unsupported host; keeping legacy companion"
    exit 0
fi

if [ -f "$DESTINATION/.blitz-version" ] &&
   [ "$(cat "$DESTINATION/.blitz-version")" = "$VERSION $SHA256" ] &&
   [ -x "$DESTINATION/bin/idb_companion" ] &&
   [ -f "$DESTINATION/Resources/libShimulator-iOS.dylib" ]; then
    echo "IDB companion ${VERSION} already installed"
    exit 0
fi

mkdir -p "$(dirname "$DESTINATION")"
STAGING=$(mktemp -d "${DESTINATION}.staging.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
curl --fail --location --silent --show-error "$URL" -o "$STAGING/archive.tar.gz"
echo "$SHA256  $STAGING/archive.tar.gz" | shasum -a 256 -c -
mkdir "$STAGING/tree"
tar -xzf "$STAGING/archive.tar.gz" -C "$STAGING/tree"
test -x "$STAGING/tree/idb_companion"
test -f "$STAGING/tree/Resources/libShimulator-iOS.dylib"
test -f "$STAGING/tree/Resources/SimulatorFrameworkBridge-iOS"
mkdir "$STAGING/tree/bin"
ln -s ../idb_companion "$STAGING/tree/bin/idb_companion"
ln -s ../idb-repl "$STAGING/tree/bin/idb-repl"
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$STAGING/tree/bin/idb_companion" --version
echo "$VERSION $SHA256" > "$STAGING/tree/.blitz-version"

BACKUP="${DESTINATION}.backup.$(date +%Y%m%d%H%M%S).$$"
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$BACKUP"; fi
if ! mv "$STAGING/tree" "$DESTINATION"; then
    if [ -e "$BACKUP" ]; then mv "$BACKUP" "$DESTINATION"; fi
    exit 1
fi
echo "Installed IDB companion ${VERSION}; previous tree retained at ${BACKUP}"
