#!/bin/bash
# Install the bundled maintenance package; keep existing MCP names.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:?Pass the Blitz Node runtime prefix}"
PACKAGE="${2:?Pass the bundled iPhone MCP tarball}"
MANIFEST="${3:-$SCRIPT_DIR/../node-toolchain.json}"
if [ ! -f "$MANIFEST" ] && [ "$#" -lt 3 ]; then
    MANIFEST="$SCRIPT_DIR/../../config/node-toolchain.json"
fi
exec python3 -B "$SCRIPT_DIR/iphone_mcp_install.py" "$PREFIX" "$PACKAGE" "$MANIFEST"
