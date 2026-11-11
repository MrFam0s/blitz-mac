---
name: blitz-release
description: Prepare, verify and submit an existing Apple app release from its development chat using Blitz Neo and the shared ASC CLI, including resuming a handed-off release.
---

# Release an app with Blitz Neo

Use the existing development chat when available. The embedded Blitz terminal and
an external chat use the same project facts, target identity and release operation.
This skill supplies procedure, **not permission** to upload, change Store records,
submit or publish. Follow the user's actual request; an explicitly authorized Blitz
release handoff already supplies its stated scope and does not need to be confirmed
again. Copying or reading an old handoff does not authorize a different release.

Creating a new App Store record is a separate operation. Use the confirmed identity
handoff and `asc-app-create-ui` for that step; its successful completion does not
authorize submitting the first version.

## Establish the target and product facts

Read applicable project instructions, `docs/blitz-product.md` when present, and the
handoff's immutable target. Verify facts against the current source and actual build.
Chat history includes plans and abandoned ideas; do not turn those into Store claims.
Keep supported features, limitations, platforms, external services, privacy facts,
test evidence and public URLs in that project document. Preserve authored text.
Unfilled sections mean unknown. Ask only for facts that cannot be established from
the project; do not infer privacy, rights, encryption or demo-login answers.

Keep project path/ID, Apple account, app ID, case-sensitive bundle ID, platform,
version ID and eventual build ID together. A dashboard selection is not identity.
Use `get_release_context` with the explicitly intended project/app IDs and compare
its returned target with the handoff before using UI-bound MCP tools. Supply the
unchanged `expectedTarget` required by those tools; if selection or account changes,
stop that operation rather than capturing and adopting the new selection.
Use separate explicit IDs for new versions/builds returned by verified operations.

The installed `asc` CLI shares Blitz's implementation and authentication. Read its
current `--help`. Pass explicit app, platform, version and build identifiers instead
of relying on defaults such as the newest version/build. Do not create another ASC
installation or export keys/session cookies. Renew required web authentication
through Blitz; a successful login is not evidence that a Store write succeeded.

## Prepare without submitting

For a normal update, compare against the source/build proven to back the prior
release. A newer file timestamp, a higher number, or an empty version draft is not
proof of releasable changes. For a prepared draft, preserve its exact version ID,
authored texts, media order and deliberate deletions. Do not refill these from an
older release. Generate missing truthful release notes from verified changes;
keep existing notes. First-release preparation does not need a fictional predecessor.

Follow the project's build/version rules, run the required tests and record actual
results plus the source commit or reproducible snapshot. Match marketing version
and build number in source, signed artifact and ASC. Inspect the actual IPA/PKG;
do not choose a file merely because it is newest. Upload only within authorized
scope. Wait for that exact build to become usable, then prepare the exact version
and attach the verified build using ASC's explicit-ID commands. `asc release stage`
prepares without submitting; inspect its local help before use.

Keep the private release report/state under the project's `.blitz/` directory and
exclude it from Git. Record source/artifact evidence, checks, exact IDs, changelog
sources, allowed changes and blockers, never credentials or demo passwords.
Coordinate one release per app/platform using the existing exclusive release lock;
reconcile a pending or uncertain operation instead of starting another one.

## Final guarded workflow

Once the build is attached and the Store content is ready:

1. Call `release_prepare` with explicit `projectId`, canonical `projectPath`, `appId`,
   exact `bundleId`, `platform` (`IOS` or `MAC_OS`), the original nonsecret `accountKey`
   (`issuerId:keyId`), `versionId`, `buildId` and the requested `releaseMode`
   (`MANUAL` or `AFTER_APPROVAL`). This reads Apple
   state and creates a private operation; it does not submit. Preserve its operation
   ID, immutable target and confirmation digest in the private release report.
2. Call `release_validate` with its `operationId` and original `accountKey`. It checks fresh scoped Store readiness
   and the saved content snapshot. These checks supplement, not replace, functional
   app tests and the reviewed product facts. Resolve blockers within the user's
   scope. If the intended content/build changes, prepare and validate its new
   snapshot; never edit a saved operation or reuse an old confirmation digest.
3. If submission is already authorized for this exact release, call `release_submit`
   with that `operationId`, original `accountKey`, `confirm: true` and the current
   `confirmationDigest` returned by validation. Otherwise present the
   concrete version/build, changes, checks and release mode before asking for the
   missing authorization. A returned digest is evidence of a snapshot, not permission.
4. Use `release_status` with `operationId` and `accountKey` to reconcile and report Apple's actual status. The operation
   records the submission boundary durably. After timeout, interruption, account
   change or an uncertain response, query status; do not replay submission through
   ASC or create a new operation to bypass an unresolved attempt.

The `~/.blitz/bin/blitz-neo release` CLI exposes the same guarded backend when available.
Read its `--help`. The `context`, `prepare`, `validate`, `status` and `submit`
subcommands accept `--request /absolute/path/request.json` with the corresponding
MCP fields as data. Do not invent commands
or replace guarded final submission with a direct CLI submission because a check
failed. If an installed toolset is older, report the missing capability.

An authentication failure during read-only preparation/validation can resume after
login with the same unchanged target. A failure after a write might have taken
effect; reconcile before any retry. App-creation retries follow their separate
stage-aware creation skill and operation journal.

Report app, exact version/build, source and artifact evidence, test outcome, remaining
blockers and verified Apple state. Distinguish “prepared”, “submitted for review”
and “published”. `AFTER_APPROVAL` means publication after Apple's approval, not an
immediate release. Do not change pricing, territories, tester groups or another app
unless the user's task specifically includes them.
