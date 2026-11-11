#!/bin/bash
# Isolated adapter tests: no live Apple profile or API requests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_BINARY="${GO:-go}"
TEST_JOBS="${BLITZ_ASC_TEST_JOBS:-2}"
case "$TEST_JOBS" in
    1|2|3|4) ;;
    *) echo "ERROR: BLITZ_ASC_TEST_JOBS must be 1, 2, 3 or 4." >&2; exit 1 ;;
esac
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export ASC_CONFIG_PATH="$TEST_DIR/absent-config.json"
export ASC_BYPASS_KEYCHAIN=1 ASC_TELEMETRY_DISABLED=1 ASC_SKILLS_AUTO_CHECK=0
export GOMAXPROCS="$TEST_JOBS"
python3 -B "$ROOT_DIR/scripts/test-asc-test-overlay.py"
HELPER_PATH="$(bash "$ROOT_DIR/scripts/build-asc-helper.sh")"
TEST_OVERLAY="$(python3 "$ROOT_DIR/scripts/prepare-asc-test-overlay.py" \
    --stage-dir "$ROOT_DIR/.build/asc-source" --output-dir "$TEST_DIR/overlay")"
(
    cd "$ROOT_DIR/.build/asc-source"
    "$GO_BINARY" test -p "$TEST_JOBS" -parallel "$TEST_JOBS" -count=1 -timeout=5m \
        -overlay "$TEST_OVERLAY" ./internal/asc ./internal/helper ./internal/cli/validate ./cmd/ascd
    "$GO_BINARY" test -p "$TEST_JOBS" -parallel "$TEST_JOBS" -count=1 -timeout=2m \
        -run '^TestBlitzReleaseTeam' ./internal/web
)
python3 "$ROOT_DIR/scripts/verify-asc-helper.py" "$HELPER_PATH"
