#!/bin/bash
# Build the pinned official ASC with Blitz's JSON-lines protocol adapter.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/deps/App-Store-Connect-CLI-helper"
STAGE_DIR="$ROOT_DIR/.build/asc-source"
OUTPUT_DIR="$ROOT_DIR/.build/ascd-helper"
GO_BINARY="${GO:-go}"
ASC_VERSION="5.15.0"
ASC_COMMIT="b9520c3865b54c5c02f905793ac3565fc2885aee"

if [ ! -f "$SOURCE_DIR/go.mod" ] || [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$ASC_COMMIT" ]; then
    echo "ERROR: Initialize the pinned ASC submodule: git submodule update --init --recursive" >&2
    exit 1
fi
command -v "$GO_BINARY" >/dev/null || { echo "ERROR: Install Go as required by the ASC go.mod, or set GO to its executable." >&2; exit 1; }

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$OUTPUT_DIR"
git -C "$SOURCE_DIR" archive "$ASC_COMMIT" | tar -x -C "$STAGE_DIR"
cp -R "$ROOT_DIR/helpers/asc-overlay/." "$STAGE_DIR/"
BUILD_DATE="$(git -C "$SOURCE_DIR" show -s --format=%cI "$ASC_COMMIT")"
echo "Building ASC $ASC_VERSION with the Blitz protocol adapter..." >&2
(
    cd "$STAGE_DIR"
    "$GO_BINARY" build -trimpath -ldflags "-s -w -X main.version=$ASC_VERSION -X main.commit=$ASC_COMMIT -X main.date=$BUILD_DATE" -o "$OUTPUT_DIR/ascd" ./cmd/ascd
)
printf '%s\n' "$OUTPUT_DIR/ascd"
