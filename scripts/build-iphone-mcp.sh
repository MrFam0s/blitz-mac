#!/bin/bash
# Build and test the pinned iPhone MCP with the maintenance fork's small overlay.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer the same supported runtime used by the installed MCP. npm 12 omits
# npm-shrinkwrap.json from tarballs, defeating our locked offline package check.
if [ -n "${BLITZ_NODE_BIN:-}" ]; then
    [ -x "$BLITZ_NODE_BIN/node" ] && [ -x "$BLITZ_NODE_BIN/npm" ] || { echo 'BLITZ_NODE_BIN must contain node and npm.' >&2; exit 1; }
    export PATH="$BLITZ_NODE_BIN:$PATH"
elif [ -x "$HOME/.blitz/node-runtime/bin/node" ] && [ -x "$HOME/.blitz/node-runtime/bin/npm" ]; then
    export PATH="$HOME/.blitz/node-runtime/bin:$PATH"
fi
NPM_VERSION=$(npm --version)
case "$NPM_VERSION" in
    10.*|11.*) ;;
    *) echo 'Use the supported Node 22/npm 10 runtime (BLITZ_NODE_BIN); this build requires npm-shrinkwrap.json in the packed helper.' >&2; exit 1 ;;
esac
echo "Building iPhone MCP with $(node --version) / npm $NPM_VERSION" >&2
SOURCE_DIR="$ROOT_DIR/deps/iPhone-mcp"
STAGE_DIR="$ROOT_DIR/.build/iphone-mcp-source"
OUTPUT_DIR="$ROOT_DIR/.build/iphone-mcp"
UPSTREAM_COMMIT=3259f756279cd8cb6bc507b46369111fb5672fa2
PATCH="$ROOT_DIR/helpers/iphone-mcp-overlay/maintenance.patch"
if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$UPSTREAM_COMMIT" ]; then
    echo 'Initialize the pinned iPhone MCP submodule first.' >&2
    exit 1
fi
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$OUTPUT_DIR"
ARCHIVE=$(mktemp)
trap 'rm -f "$ARCHIVE"' EXIT
git -C "$SOURCE_DIR" archive --format=tar --output="$ARCHIVE" "$UPSTREAM_COMMIT"
tar -xf "$ARCHIVE" -C "$STAGE_DIR"
git -C "$ROOT_DIR" apply --directory=.build/iphone-mcp-source "$PATCH"
PATCH_SHA=$(shasum -a 256 "$PATCH" | awk '{print $1}')
node --input-type=module - "$STAGE_DIR/package.json" "$UPSTREAM_COMMIT" "$PATCH_SHA" <<'JS'
import fs from 'node:fs';
const [file,upstreamCommit,overlaySHA256]=process.argv.slice(2);
const pkg=JSON.parse(fs.readFileSync(file,'utf8'));
pkg.blitzMaintenance={upstreamVersion:'0.1.18',upstreamCommit,overlaySHA256};
pkg.allowScripts={'unix-dgram@2.0.7':true};
pkg.files=[...pkg.files,'npm-shrinkwrap.json'];
fs.writeFileSync(file,JSON.stringify(pkg,null,2)+'\n');
JS
(
    cd "$STAGE_DIR"
    npm ci --ignore-scripts --no-audit --no-fund >&2
    # Build the only required native addon explicitly; do not run arbitrary
    # dependency lifecycle scripts during the source build.
    npm rebuild unix-dgram --strict-allow-scripts >&2
    # Recent npm can otherwise report a successful rebuild after skipping the
    # native lifecycle script. Fail before packaging an unusable helper.
    node -e "require('unix-dgram')" >&2
    npm test >&2
    # npm only honors a package's published npm-shrinkwrap.json during global
    # installation; package-lock.json alone would allow dependency drift.
    cp package-lock.json npm-shrinkwrap.json
    npm pack --ignore-scripts --pack-destination "$OUTPUT_DIR" >/dev/null
)
PACKAGE="$OUTPUT_DIR/blitzdev-iphone-mcp-0.1.18-blitz.1.tgz"
shasum -a 256 "$PACKAGE" | awk '{print $1}' > "$PACKAGE.sha256"
printf '%s\n' "$PACKAGE"
