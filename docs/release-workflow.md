# Releases from an existing development chat

Blitz Neo 1.0.67 uses one release backend for the manual submission preview,
MCP tools and the thin `~/.blitz/bin/blitz-neo release` CLI. ASC remains the shared
build/upload/metadata implementation. No extra server, credential store, paid CI,
or separate ASC installation is needed. Blitz Neo must be running for its MCP/CLI.

## Handoff and evidence

The app-creation and automatic-release dialogs offer **Im bestehenden Chat
fortsetzen** as the preferred path and retain **Im Blitz-Terminal starten**.
Copying the handoff neither submits a release nor starts an agent. Paste it into
the development chat when ready to execute the explicitly described scope.
App-creation handoffs preserve the exact previously confirmed identity and
operation; they do not implicitly authorize the first version's submission.

The release handoff creates `docs/blitz-product.md` only if absent. Fill it with
verified product facts, limitations, platforms, privacy facts, URLs and test
evidence. Existing authored content is never overwritten. Chat memory alone is
not evidence that a feature exists in the released build. The managed
`blitz-release` skill is synchronized to both project agent directories.

Private handoffs live under `.blitz/release-handoff/` with an ignore-all file.
Agent release reports belong in ignored `.blitz/release-automation/`; keep actual
source/artifact checksums, version/build, changelog sources, test results and
blockers there. Backend journals live outside repositories in
`~/.blitz/release-operations/`, contain no credentials or raw Store review text,
and must not be edited to bypass a blocked operation.

## API and CLI

`blitz-neo release --help` documents the adapter. Every command accepts one JSON
argument file (`--request /absolute/path/request.json`, or `--request -` for stdin).
There is no shell interpolation or generic remote-command execution.

| CLI command | MCP tool | Effect |
| --- | --- | --- |
| `context` | `get_release_context` | Verify the explicitly requested current UI target |
| `prepare` | `release_prepare` | Read Apple and record a fixed release snapshot |
| `validate` | `release_validate` | Fresh readiness and unchanged-content checks |
| `status` | `release_status` | Read-only reconciliation after delay/restart |
| `submit` | `release_submit` | Guarded release-mode update and review submission |

`release_prepare` requires `projectId`, canonical `projectPath`, `appId`, exact
`bundleId`, `platform` (`IOS`/`MAC_OS`), nonsecret `accountKey` (`issuerId:keyId`),
`versionId`, `buildId`, and `releaseMode` (`MANUAL`/`AFTER_APPROVAL`). There is no
fallback to the UI selection or newest build. The exact valid build must already
be attached, using the existing explicit-ID ASC preparation/upload flow.

The response contains `operationId`, `target`, `mode`, `state`, version/build and
`confirmationDigest`. `validate` and `status` require `operationId` and original
`accountKey`. `submit` additionally requires `confirm: true` and that exact digest.
The digest identifies reviewed content; it is not user authorization. Preparation
alone never authorizes submission. The manual UI uses the same backend and can
attach its explicitly chosen build under the same durable operation lock.

CLI output is JSON. Protocol errors, malformed replies, blocked validation and
unconfirmed submission exit nonzero. A successful `status` query can describe an
unresolved operation and exit zero: callers must inspect `state`/`appleState`.
`submitted` does not mean published or currently sold on the App Store.

## Scope and recovery

UI-bound Store tools now require `expectedTarget` returned by
`get_release_context(projectId, appId)`. It includes exact project/path/app/bundle/
platform/account and explicit nullable `versionId`. Missing/mismatched targets
fail before navigation or approval; a UI switch aborts subsequent writes.
An intended version switch returns a new context. `settings.bundleId` requires
the intended `projectId` instead because the Store app does not exist yet.
Creation confirmation/reopening keep their separate confirmed-operation checks.

The independent release tools do not navigate the UI. They use the registered
project, captured account, fixed version and build, per-app/platform process locks
and durable intent journals. Metadata/media fingerprints are checked before the
final submission. Known preflight authentication failures can resume after login.
A lost write response is uncertain: inspect `status`; never repeat the command
through raw ASC or create a new operation to bypass the journal. An unresolved
partial Apple submission requires investigation; the backend does not delete or
silently adopt another submission.

Apple readiness validation is not functional software testing. The originating
chat still verifies source provenance, artifact identity, functionality and true
product claims. External clients can edit Apple independently; this workflow
detects changed content and serializes its own release steps but cannot provide
an atomic transaction across Apple's API.

Older connected chats may retain the old MCP schema until reconnecting. The new
CLI can be used immediately after installation with the same backend and guards.
Existing unscoped tool calls fail clearly instead of acting on an arbitrary app.

## Local verification

Run `swift test --build-system native --jobs 4`, both offline creation Python
suites, and the signed native bundle build. The suite includes actual Unix-socket
tests for reply loss and a saturated connection queue, injected Apple transport
tests, wrong-target/build checks, content changes, persisted recovery and exact
handoff identities. No live Store mutation is necessary to test these paths.
