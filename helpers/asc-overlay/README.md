# ASC integration in Blitz

Blitz Neo builds official ASC **6.6.1**, commit
`d8ccc609bb0bcb3a4fd169c5fee388d5ba02018b`, from
https://github.com/rorkai/App-Store-Connect-CLI.

The upstream source is an unmodified pinned submodule. `scripts/build-asc-helper.sh`
exports it into `.build/asc-source`, adds this overlay and builds `cmd/ascd`.
Go must satisfy upstream's `go.mod` (currently Go 1.27.3).

This adapter originates from the former Blitz ASC fork, commit
`c17dc0836359dc272ad4df9521dc4b642e1dd13f` at
https://github.com/pythonlearner1025/App-Store-Connect-CLI. Its MIT license is
retained here. The adapter's CLI mode calls the current upstream `cmd.Run`;
its default mode serves Blitz's existing JSON-lines protocol. Both modes
therefore share one ASC implementation, credentials resolver and command tree.
The old fork's additional analytics launcher is not included.

`session.request` deliberately preserves HTTP status, headers and raw body,
including non-2xx responses: Blitz owns their interpretation. This path retains
the original HTTP response semantics while using current upstream authentication,
target validation and redirect rejection. The protocol server allows at most four
GET/HEAD reads concurrently. Session changes, CLI execution and mutations wait for
preceding reads and execute in order; responses are correlated by request ID.
The production entry point reserves the original stdout for JSON-lines responses
and redirects incidental library output to stderr once at startup, so reads do
not contend on a process-wide stdout-capture lock. CLI mode keeps normal output.
The upstream CLI retains its own current retry/error behavior.

The app daemon pins authentication to the key selected in Blitz. It removes
inherited `ASC_BEARER_TOKEN` and `ASC_KEY_TYPE` before starting the helper, so
`cli.exec` uploads cannot silently use a different account or the Enterprise API
while `session.request` uses the selected App Store Connect key. Direct terminal
CLI execution keeps its explicit caller environment, including these new modes.

Optional upstream FIDO2 support is not compiled into this helper. Official ASC
macOS releases enable `-tags fido2` and statically link additional native
libraries; this fork's ordinary Go build does not. Fresh CLI sign-in requiring a
USB security key therefore remains unavailable in this helper. Blitz's
existing WebKit sign-in and session-import path are unchanged. This is an absent
new optional 6.4 feature, not a removed 5.17 capability.

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
