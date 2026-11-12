#!/bin/bash
# Build and test the pinned iPhone MCP with the maintenance fork's small overlay.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/node-toolchain.sh"
blitz_resolve_node_toolchain "$ROOT_DIR/config/node-toolchain.json"
echo "Building iPhone MCP with $(node --version) / npm $(npm --version)" >&2
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
node --input-type=module - "$STAGE_DIR/package.json" "$UPSTREAM_COMMIT" "$PATCH_SHA" "$ROOT_DIR/config/node-toolchain.json" <<'JS'
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const [file,upstreamCommit,overlaySHA256,toolchainFile]=process.argv.slice(2);
const {nodeVersion,npmVersion}=JSON.parse(fs.readFileSync(toolchainFile,'utf8'));
const dependencyLockSHA256=createHash('sha256').update(fs.readFileSync(file.replace(/package\.json$/,'package-lock.json'))).digest('hex');
const pkg=JSON.parse(fs.readFileSync(file,'utf8'));
pkg.blitzMaintenance={upstreamVersion:'0.1.18',upstreamCommit,overlaySHA256,dependencyLockSHA256,toolchain:{nodeVersion,npmVersion}};
pkg.allowScripts={'unix-dgram@2.0.7':true};
pkg.files=[...pkg.files,'package-lock.json'];
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
    # npm 12 excludes lockfiles; our private distribution adds the exact
    # package-lock.json below so installation uses the same npm ci contract.
    npm pack --ignore-scripts --pack-destination "$OUTPUT_DIR" >/dev/null
)
PACKAGE="$OUTPUT_DIR/blitzdev-iphone-mcp-0.1.18-blitz.1.tgz"
python3 "$ROOT_DIR/scripts/pack-iphone-mcp.py" "$STAGE_DIR" "$PACKAGE" "$ROOT_DIR/config/node-toolchain.json"
python3 "$ROOT_DIR/scripts/verify-iphone-mcp.py" "$PACKAGE" >&2
printf '%s\n' "$PACKAGE"
