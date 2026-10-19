#!/bin/bash
# Install the bundled maintenance package atomically; keep existing MCP names.
set -euo pipefail
PREFIX="${1:?Pass the Blitz Node runtime prefix}"
PACKAGE="${2:?Pass the bundled iPhone MCP tarball}"
VERSION=0.1.18-blitz.1
NODE="$PREFIX/bin/node"
NPM="$PREFIX/bin/npm"
DESTINATION="$PREFIX/lib/node_modules/@blitzdev/iphone-mcp"
EXPECTED=$(cat "$PACKAGE.sha256")
ACTUAL=$(shasum -a 256 "$PACKAGE" | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] || { echo 'iPhone MCP checksum mismatch' >&2; exit 1; }
[ -x "$NODE" ] && [ -x "$NPM" ]
STAGING=$(mktemp -d "$PREFIX/.iphone-mcp-install.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
STAGED_PACKAGE="$STAGING/package"
mkdir "$STAGED_PACKAGE"
tar -xzf "$PACKAGE" -C "$STAGED_PACKAGE" --strip-components=1
[ -f "$STAGED_PACKAGE/npm-shrinkwrap.json" ]
[ "$("$NODE" -p "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).version" "$STAGED_PACKAGE/package.json")" = "$VERSION" ]
"$NODE" --input-type=module - "$STAGED_PACKAGE/package.json" <<'JS'
import fs from 'node:fs';
const pkg=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(pkg.blitzMaintenance?.upstreamCommit!=='3259f756279cd8cb6bc507b46369111fb5672fa2') process.exit(1);
JS
# Global `npm install` can re-resolve the published dependency ranges. Install
# the staged application with `ci` so the shipped lockfile is mandatory.
(
    cd "$STAGED_PACKAGE"
    export PATH="$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "$NPM" ci --omit=dev --ignore-scripts --no-audit --no-fund
    "$NPM" rebuild unix-dgram --no-audit --no-fund
)
"$NODE" --input-type=module - "$STAGED_PACKAGE/dist/index.js" <<'JS'
import {pathToFileURL} from 'node:url';
await import(pathToFileURL(process.argv[2]).href);
JS
mkdir -p "$(dirname "$DESTINATION")"
BACKUP="${DESTINATION}.backup.$(date +%Y%m%d%H%M%S).$$"
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$BACKUP"; fi
if ! mv "$STAGED_PACKAGE" "$DESTINATION"; then
    if [ -e "$BACKUP" ]; then mv "$BACKUP" "$DESTINATION"; fi
    exit 1
fi
ln -s ../lib/node_modules/@blitzdev/iphone-mcp/dist/cli.js "$STAGING/iphone-mcp"
mv -f "$STAGING/iphone-mcp" "$PREFIX/bin/iphone-mcp"
echo "Installed iPhone MCP $VERSION; previous package retained at $BACKUP"
