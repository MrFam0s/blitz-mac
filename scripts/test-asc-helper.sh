#!/bin/bash
# Isolated adapter tests: no live Apple profile or API requests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_BINARY="${GO:-go}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export ASC_CONFIG_PATH="$TEST_DIR/absent-config.json"
export ASC_BYPASS_KEYCHAIN=1 ASC_TELEMETRY_DISABLED=1 ASC_SKILLS_AUTO_CHECK=0
HELPER_PATH="$(bash "$ROOT_DIR/scripts/build-asc-helper.sh")"
(
    cd "$ROOT_DIR/.build/asc-source"
    "$GO_BINARY" test ./internal/asc ./internal/helper ./cmd/ascd
)
python3 "$ROOT_DIR/scripts/verify-asc-helper.py" "$HELPER_PATH"
