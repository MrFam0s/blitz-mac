#!/bin/bash
# test-build-workflow.sh — locally validate and exercise the GitHub Actions macOS workflow.
#
# This script is intentionally conservative:
# - It always statically validates `.github/workflows/build.yml`.
# - It only runs jobs that match the current host architecture on macOS.
#
# Usage:
#   bash scripts/test-build-workflow.sh
#   bash scripts/test-build-workflow.sh --validate-only
#   bash scripts/test-build-workflow.sh --job build
#   bash scripts/test-build-workflow.sh --job build_x86_64
#
# Environment:
#   ACT_ARGS               Additional arguments appended to `act`
#   ACTIONLINT_REQUIRED=1  Fail static validation if actionlint is not installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_PATH="$ROOT_DIR/.github/workflows/build.yml"

JOB=""
VALIDATE_ONLY=false
ARTIFACT_DIR="$ROOT_DIR/.artifacts/act"

usage() {
    cat <<'EOF'
Usage: bash scripts/test-build-workflow.sh [options]

Options:
  --job <name>            Job to run with act.
                          Supported: build, build_x86_64
  --artifact-dir <dir>    Directory for act artifacts. Default: .artifacts/act
  --validate-only         Run only static validation, skip act execution
  --help                  Show this help

Notes:
  - Default job is selected from the current host architecture:
      arm64  -> build
      x86_64 -> build_x86_64
  - Local execution is only considered valid when host architecture matches the
    job's intended runner architecture.
EOF
}

log() {
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --job)
            [ $# -ge 2 ] || die "--job requires a value"
            JOB="$2"
            shift 2
            ;;
        --artifact-dir)
            [ $# -ge 2 ] || die "--artifact-dir requires a value"
            ARTIFACT_DIR="$2"
            shift 2
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -f "$WORKFLOW_PATH" ] || die "workflow not found at $WORKFLOW_PATH"

host_arch() {
    uname -m
}

default_job_for_host() {
    case "$(host_arch)" in
        arm64) echo "build" ;;
        x86_64) echo "build_x86_64" ;;
        *) die "unsupported host architecture: $(host_arch)" ;;
    esac
}

required_host_for_job() {
    case "$1" in
        build) echo "arm64" ;;
        build_x86_64) echo "x86_64" ;;
        *) die "unsupported job: $1" ;;
    esac
}

runner_label_for_job() {
    case "$1" in
        build) echo "macos-15" ;;
        build_x86_64) echo "macos-15-intel" ;;
        *) die "unsupported job: $1" ;;
    esac
}

validate_yaml() {
    log "Validating workflow YAML syntax"

    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY' "$WORKFLOW_PATH"
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    print("PyYAML is not installed", file=sys.stderr)
    sys.exit(2)

with Path(sys.argv[1]).open("r", encoding="utf-8") as fh:
    yaml.safe_load(fh)

print("YAML OK")
PY
        return
    fi

    die "python3 with PyYAML is required for YAML validation"
}

validate_with_actionlint() {
    if command -v actionlint >/dev/null 2>&1; then
        log "Running actionlint"
        actionlint "$WORKFLOW_PATH"
        return
    fi

    if [ "${ACTIONLINT_REQUIRED:-0}" = "1" ]; then
        die "actionlint is not installed"
    fi

    log "Skipping actionlint (not installed)"
}

write_event_file() {
    local event_file="$1"
    local ref="$2"

    cat > "$event_file" <<EOF
{
  "ref": "$ref",
  "repository": {"private": false}
}
EOF
}

run_act_job() (
    local job="$1"
    local required_host="$2"
    local runner_label="$3"
    local ref="$4"
    local event_file
    local act_args=()

    [ "$(host_arch)" = "$required_host" ] || die "job '$job' should be tested on $required_host, current host is $(host_arch)"
    command -v act >/dev/null 2>&1 || die "act is not installed. Install with 'brew install act'"

    mkdir -p "$ARTIFACT_DIR"
    event_file="$(mktemp)"
    trap 'rm -f "$event_file"' EXIT
    write_event_file "$event_file" "$ref"

    act_args+=("workflow_dispatch")
    act_args+=("-W" "$WORKFLOW_PATH")
    act_args+=("-j" "$job")
    act_args+=("-P" "$runner_label=-self-hosted")
    act_args+=("-e" "$event_file")
    act_args+=("--artifact-server-path" "$ARTIFACT_DIR")

    if [ -n "${ACT_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        local extra_args=( ${ACT_ARGS} )
        act_args+=("${extra_args[@]}")
    fi

    log "Running act job '$job' on runner label '$runner_label'"
    (
        cd "$ROOT_DIR"
        act "${act_args[@]}"
    )
)

validate_yaml
validate_with_actionlint

if [ "$VALIDATE_ONLY" = true ]; then
    log "Static validation completed"
    exit 0
fi

if [ -z "$JOB" ]; then
    JOB="$(default_job_for_host)"
fi

required_host="$(required_host_for_job "$JOB")"
runner_label="$(runner_label_for_job "$JOB")"
run_act_job "$JOB" "$required_host" "$runner_label" "refs/heads/main"
