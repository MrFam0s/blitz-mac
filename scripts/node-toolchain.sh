#!/bin/bash
# Source this file, then call blitz_resolve_node_toolchain. No download or mutation.

blitz_resolve_node_toolchain() {
    local manifest="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/node-toolchain.json}"
    local versions node_version npm_version candidate resolved=""
    versions=$(python3 - "$manifest" <<'PY'
import json,re,sys
data=json.load(open(sys.argv[1]))
assert data['schemaVersion']==1
for key in ['nodeVersion','npmVersion']:
    assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', data[key]), key
print(data['nodeVersion'],data['npmVersion'])
PY
    ) || return 1
    read -r node_version npm_version <<< "$versions"
    if [ -n "${BLITZ_NODE_BIN:-}" ]; then
        candidate="$BLITZ_NODE_BIN"
        if ! blitz_node_toolchain_matches "$candidate" "$node_version" "$npm_version"; then
            echo "BLITZ_NODE_BIN must provide Node $node_version and npm $npm_version (config/node-toolchain.json)." >&2
            return 1
        fi
        resolved="$candidate"
    else
        candidate="$(command -v node || true)"
        if [ -n "$candidate" ]; then
            candidate="$(dirname "$candidate")"
            if blitz_node_toolchain_matches "$candidate" "$node_version" "$npm_version"; then
                resolved="$candidate"
            fi
        fi
        if [ -z "$resolved" ] && blitz_node_toolchain_matches "$HOME/.blitz/node-runtime/bin" "$node_version" "$npm_version"; then
            resolved="$HOME/.blitz/node-runtime/bin"
        fi
    fi
    if [ -z "$resolved" ]; then
        echo "Blitz requires Node $node_version and npm $npm_version. Set BLITZ_NODE_BIN to the tested toolchain's bin directory." >&2
        return 1
    fi
    BLITZ_NODE_BIN="$(cd "$resolved" && pwd)"
    export BLITZ_NODE_BIN
    export PATH="$BLITZ_NODE_BIN:$PATH"
}

blitz_node_toolchain_matches() {
    local bin="$1" node_version="$2" npm_version="$3" actual
    [ -x "$bin/node" ] && [ -x "$bin/npm" ] || return 1
    actual=$("$bin/node" --version 2>/dev/null) || return 1
    [ "$actual" = "v$node_version" ] || return 1
    actual=$(PATH="$bin:$PATH" "$bin/npm" --version 2>/dev/null) || return 1
    [ "$actual" = "$npm_version" ]
}
