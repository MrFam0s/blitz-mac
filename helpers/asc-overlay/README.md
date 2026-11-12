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
WebKit sign-in remains available. This is an absent
new optional 6.4 feature, not a removed 5.17 capability.

To update, advance the submodule, update the version/commit in the build script
and bundle verification, then run transport and protocol tests in the staged
source. Do not replace `ascd` with an ordinary upstream release executable: the
Swift app requires its protocol adapter. Do not edit the generated staging tree.

```sh
bash scripts/test-asc-helper.sh
```

The helper tests compare CLI output/exit codes across the entire command tree;
HTTP tests use mocked transport and do not write to App Store Connect.

## Browser session import

`web.session.import` validates a portable browser bundle in an isolated cookie jar
against its exact Apple account and freshly selected public provider ID. The result
separates ASC and Developer Portal capability from agreement acceptance. A valid
existing CLI session with equal or stronger capabilities is preserved byte-for-byte;
cookies from different sessions are never merged. A verified replacement commits
through upstream's atomic persistence under the same lock order, only if snapshots
of all affected backends and last-account pointers have not changed during network
validation. A concurrent CLI login or divergent secondary cache stops the import.
Unverifiable current sessions are not treated as expired. Receipts contain only
fixed reason codes, capability states and nonsecret account/provider/team identity.

The native app keeps its own WebKit/Iris snapshot and fresh legacy-script export.
It no longer rewrites the shared ASC Keychain store or restores an old aggregate
Keychain snapshot at startup. Normal ASC login does not demand Portal access; a
Portal-specific login request visits that origin and requires separate proof.
The offline `TestBlitzSession` regressions exercise preservation, scoped replacement,
identity conflicts, interrupted persistence and concurrent cache changes.

## Bound release readiness

`release.readiness` is a fixed, read-only protocol operation for an explicit
app/bundle/version/platform. It uses upstream's `BuildReadinessReport` with
strict public validation, including deep public IAP and pricing checks. The
small `internal/cli/validate/blitz_release.go` addition applies the unchanged
upstream private checks to one web client, after that client has returned the
exact app ID and case-sensitive bundle ID in the selected provider. It never
falls back to a different default cache for the individual private checks.

The helper separately reports the current Developer Program License and the
relevant Free/Paid Applications Business contracts. It clears the cached Portal
team only in memory and requires a unique exact provider-ID or provider-name
match in the fresh team list before upstream revalidates that explicit team.
An unrelated sole team or a name prefix is insufficient for release evidence.
A missing/expired Portal session, unresolved team, partial history, unclassified
outstanding agreement or unavailable Business response remains **unverified**.
An active Business contract alone cannot prove the Program License accepted.
Known pending agreements and upstream fatal findings remain blocking. No
agreement acceptance or other Store mutation is performed by this operation.
Only fixed reason codes and non-secret scope identifiers accompany the normal
validation report; raw authentication errors and legal-entity data are omitted.

Swift interprets What's New using fresh, completely paginated publication
history for the exact platform, including removed and replaced releases. It does
not infer an initial release from a `1.0` version string. It only normalizes the
upstream warning after that evidence is complete and retains unrelated warnings,
fatal checks and genuinely unverifiable evidence. Private raw reports remain in
memory; saved operations contain generated diagnostics and stable check IDs.

Offline coverage includes first publication at 1.2, an update numbered 1.0,
withdrawn first submissions, removed/replaced history, platform separation,
incomplete pages, provider mismatch, active Business with unknown Program
License, current versus older licenses and outstanding contract changes.
Run `go test ./internal/helper ./internal/cli/validate` in the staged source in
addition to the transport and CLI compatibility checks above.

## Upstream test-only stdout capture workaround

ASC 6.6.1's `captureXcodeCloudStdout` writes to an `os.Pipe` synchronously
before draining it. The wide Xcode Cloud table can fill that pipe on macOS and
deadlock the otherwise unchanged `internal/asc` tests. The existing upstream
`captureStdout` already drains concurrently and closes both descriptors.

`scripts/prepare-asc-test-overlay.py` verifies both complete helper functions and
their expected imports, then creates a temporary replacement test file that
delegates to the existing safe helper. A Go `-overlay` JSON file points only to
that `_test.go` file. It changes neither the pinned submodule nor the staging
tree or production binary. Changed upstream helpers/import usage fail closed:
review or remove the workaround when advancing the ASC pin.

`scripts/test-asc-helper.sh` runs the generator's offline regression tests, builds
the helper, and applies that test overlay with bounded parallelism (default 2,
`BLITZ_ASC_TEST_JOBS` accepts 1–4). It includes `internal/asc`, `internal/helper`,
`internal/cli/validate` and the `TestBlitzReleaseTeam`/`TestBlitzSession` web regressions. To
reuse an existing staging tree without rebuilding:

```sh
test_overlay_dir="$(mktemp -d)"
test_overlay="$(python3 scripts/prepare-asc-test-overlay.py \
  --stage-dir .build/asc-source --output-dir "$test_overlay_dir")"
# Keep the same isolated ASC_CONFIG_PATH and authentication-free test environment.
(cd .build/asc-source && go test -p 2 -parallel 2 -count=1 \
  -overlay "$test_overlay" ./internal/asc)
rm -rf "$test_overlay_dir"
```
