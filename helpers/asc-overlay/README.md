# ASC integration in Blitz

Blitz 1.0.37 builds official ASC **5.15.0**, commit
`b9520c3865b54c5c02f905793ac3565fc2885aee`, from
https://github.com/rorkai/App-Store-Connect-CLI.

The upstream source is an unmodified pinned submodule. `scripts/build-asc-helper.sh`
exports it into `.build/asc-source`, adds this overlay and builds `cmd/ascd`.
Go must satisfy upstream's `go.mod` (currently Go 1.27.2).

This adapter originates from the former Blitz ASC fork, commit
`c17dc0836359dc272ad4df9521dc4b642e1dd13f` at
https://github.com/pythonlearner1025/App-Store-Connect-CLI. Its MIT license is
retained here. The adapter's CLI mode calls the current upstream `cmd.Run`;
its default mode serves Blitz's existing JSON-lines protocol. Both modes
therefore share one ASC implementation, credentials resolver and command tree.
The old fork's additional analytics launcher is not included.

`session.request` deliberately preserves HTTP status, headers and raw body,
including non-2xx responses: Blitz owns their interpretation. This path retains
the original single-request semantics and mutation concurrency limit, while
using current upstream authentication, target validation and redirect rejection.
The upstream CLI retains its own current retry/error behavior.

To update, advance the submodule, update the version/commit in the build script
and bundle verification, then run transport and protocol tests in the staged
source. Do not replace `ascd` with an ordinary upstream release executable: the
Swift app requires its protocol adapter. Do not edit the generated staging tree.

```sh
bash scripts/build-asc-helper.sh
cd .build/asc-source
ASC_BYPASS_KEYCHAIN=1 ASC_TELEMETRY_DISABLED=1 \
  ASC_CONFIG_PATH=/tmp/blitz-no-auth.json \
  go test ./internal/asc ./internal/helper
```

The helper tests compare CLI output/exit codes across the entire command tree;
HTTP tests use mocked transport and do not write to App Store Connect.
