# Releases from an existing development chat

Starting with 1.0.68, registered projects receive a small managed routing block
at the beginning of `AGENTS.md` and `CLAUDE.md` (also `AGENTS.override.md` if it
exists). **Update einreichen** selects the `blitz-release` skill and defaults to
the Blitz Neo CLI. The explicit request covers the appropriate update preparation,
tests, exact build/upload and submission with automatic publication after Apple's
approval, unless the user or a deliberate release policy specifies otherwise.
Preparation-only requests remain preparation-only. Existing project identity,
versioning and test requirements are preserved.

**App im App Store neu erstellen** selects `asc-app-create-ui`, checks for an
existing record and uses Blitz's exact confirmed identity operation. It creates
only the app record; it does not upload, submit or publish the first version.
Neither routing rule starts work without the actual user request. These explicit
routes supersede legacy generic MCP-first/final-submit instructions, preserving
all authored text outside the managed block. Startup and project setup refresh
the bundled skills and routing without requiring a prior handoff button click.

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
| `targets` | `get_release_targets` | List the explicitly named project's local release targets and Store bindings |
| `context` | `get_release_context` | Verify the explicitly requested current UI target |
| `prepare` | `release_prepare` | Read Apple and record a fixed release snapshot |
| `prepare-resubmission` | `release_prepare_resubmission` | Prepare the exact resolved review again with a fresh content snapshot |
| `validate` | `release_validate` | Fresh readiness and unchanged-content checks |
| `status` | `release_status` | Read-only reconciliation after delay/restart |
| `submit` | `release_submit` | Guarded release-mode update and review submission |

Start with `blitz-neo release targets --request /absolute/path/targets.json`,
where the request contains `{"projectId":"the-registered-project-id"}`. Its result
includes the canonical `projectPath`, `releaseTargets` and
`requiresReleaseTargetId`. Each target has its stable `releaseTargetId`, native
`platform`, exact `bundleId` and any verified `storeBinding` (app ID, account
fingerprint, bundle ID and SKU). This is local configuration, not a fresh Apple
readiness check or permission to create/submit an app.

`release_prepare` requires `projectId`, canonical `projectPath`, `appId`, exact
`bundleId`, `platform` (`IOS`/`MAC_OS`/`TV_OS`/`VISION_OS`), nonsecret `accountKey` (`issuerId:keyId`),
`versionId`, `buildId`, and `releaseMode` (`MANUAL`/`AFTER_APPROVAL`). Include the
discovered `releaseTargetId`; it is required when several targets exist. There is no
fallback to the UI selection or newest build. The exact valid build must already
be attached, using the existing explicit-ID ASC preparation/upload flow.

The response contains `operationId`, `target`, `mode`, `state`, version/build and
`confirmationDigest`. `validate` and `status` require `operationId` and original
`accountKey`. `submit` additionally requires `confirm: true` and that exact digest.
Later commands may assert `releaseTargetId`, but cannot use it to retarget a saved
operation. New operation records persist the resolved target ID in their immutable
`target`; it participates in the confirmation digest.
The digest identifies reviewed content; it is not user authorization. Preparation
alone never authorizes submission. The manual UI uses the same backend and can
attach its explicitly chosen build under the same durable operation lock.

CLI output is JSON. Protocol errors, malformed replies, blocked validation and
unconfirmed submission exit nonzero. A successful `status` query can describe an
unresolved operation and exit zero: callers must inspect `state`/`appleState`.
`submitted` records a historically acknowledged send. It does not mean that Apple
is currently reviewing the version, that it was resubmitted after rejection, or
that it is published. Read the current `appleState` and `submissionState` too.

## Joint app, purchase and subscription review

Starting with 1.0.73, `prepare` accepts optional `reviewItems`, the exact additional
metadata versions to submit with the app version. Each entry has only `type` and
`id`; accepted resource types are `inAppPurchaseVersions`, `subscriptionVersions`
and `subscriptionGroupVersions`. These IDs belong to reviewable metadata versions,
not parent purchase/subscription/group resources or product identifier strings.
For example, add this member to the complete preparation request:

```json
"reviewItems": [
  {"type": "inAppPurchaseVersions", "id": "purchase-version-id"},
  {"type": "subscriptionGroupVersions", "id": "group-version-id"},
  {"type": "subscriptionVersions", "id": "subscription-version-id"}
]
```

Omission or `[]` retains the app-only workflow. At most 199 distinct additional
versions accompany the one app version. No product is selected automatically.
The canonical selection appears in the returned `target` and is immutable for
that operation. `validate`, `status` and `submit` reject replacement identity or
selection fields instead of silently ignoring them. Changing the selection before
submission requires a newly prepared and validated operation. A pending write
must first be reconciled; new preparation cannot bypass it.

Use the `asc-iap-attach` skill to discover the exact versions through the installed
ASC CLI and prepare their metadata. Apple's first purchase of each type needs an
app version in the same submission. A new subscription requires its unapproved
group in that draft too; a new group must include a subscription. See
[Apple's submission rules](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase).
Blitz verifies ownership and required dependencies and binds selected product
metadata and review images into the prepared fingerprint. Pricing and availability
remain preparation tasks; final submission does not modify them. The backend uses
the [public metadata-version review API](https://developer.apple.com/documentation/appstoreconnectapi/migrating-in-app-purchase-metadata-to-v2),
not browser-cookie scripts or the legacy `submitWithNextAppStoreVersion` flag.

`prepare` and `validate` do not attach products or otherwise write to Apple.
`submit` creates one draft, adds only the prepared app/product versions, verifies
its exact complete contents, and submits once. A partial draft is resumable only
when it belongs to the persisted operation and contains no foreign items. Explicit
continuation can add missing selected items, without creating another submission
or duplicating confirmed items. A changed product/review image, unknown item,
wrong app or ambiguous draft stops the workflow. A lost final-submit response
never authorizes repeating that request. Legacy app-only journals remain readable.

The Overview product row is selection guidance, not attachment evidence. It no
longer reads a private web-session flag or instructs agents to use Iris. Complete
readiness and the exact selected set are checked by the guarded release workflow.
The existing manual app-only submission preview does not implicitly include products;
use CLI/MCP with an explicit selection for a joint release.

## Projects with more than one release target

Blitz Neo 1.0.69 separates a local project from its native release targets. Each
target has its own platform, exact bundle ID, scheme/configuration/destination,
and Store binding. A native iOS and native macOS app may use the same Store app
ID and SKU; versions, builds, screenshots and release checks still belong to the
chosen platform. Separate Store products instead keep their distinct app IDs,
bundle IDs and SKUs. Do not create a second app record just because a second
native platform is being added to the existing product.

For **Update einreichen** with several configured targets, use the platform named
in the user's request or the exact target in an authorized handoff. If that scope
is ambiguous, ask which target. The current dashboard selection never chooses an
external release implicitly. A request to release both platforms requires separate
operations and evidence for each; no CLI/MCP call automatically submits all targets.
For example, a pending iOS review does not select the iOS build for a requested
macOS release or authorize changing the iOS submission.

The compatible single-target representation has ID `legacy`, including ordinary
first imports. An omitted target ID can resolve only when exactly one target
exists. That single target can operate without a saved Store binding after exact
live account/app/bundle verification. Additional targets must be explicitly bound
to their intended Store record before release preparation. Old operation records
without a target ID remain readable; an ambiguous current project cannot silently
give them a different meaning. Retain the saved operation and reconcile its
identity before attempting further writes.

Mac Catalyst is a native `MAC_OS` release using
`generic/platform=macOS,variant=Mac Catalyst`; a native Mac target uses
`generic/platform=macOS`. An iPhone/iPad app merely available on Apple-silicon Macs
remains an `IOS` release. Signing caches and generated signing files are separated
by account, native platform and bundle ID. Old unscoped caches are retained but
not reused without trustworthy scope; profile-name conflicts stop for
reconciliation instead of deleting existing profiles.

## Scope and recovery

UI-bound Store tools now require `expectedTarget` returned by
`get_release_context(projectId, appId, releaseTargetId)`. The target ID is required
for multi-target projects and must match the current UI target. The returned
`expectedTarget` includes exact project/path/app/bundle/platform/account, configured
target ID and explicit nullable `versionId`. Missing/mismatched targets
fail before navigation or approval; a UI switch aborts subsequent writes.
An intended version switch returns a new context. `settings.bundleId` requires
the intended `projectId` instead because the Store app does not exist yet.
Creation confirmation/reopening keep their separate confirmed-operation checks;
new creation handoffs also carry `releaseTargetId` where present.

The independent release tools do not navigate the UI. They use the registered
project, captured account, fixed version and build, per-app/platform process locks
and durable intent journals. Metadata/media fingerprints are checked before the
final submission. Known preflight authentication failures can resume after login.
A lost write response is uncertain: inspect `status`; never repeat the command
through raw ASC or create a new operation to bypass the journal. An unresolved
partial Apple submission requires investigation; the backend does not delete or
silently adopt another submission.

### Continue a verified draft

Starting with 1.0.70, `status` distinguishes the active submission from historical
`COMPLETE` records. `READY_FOR_REVIEW` is a valid intermediate state after the
version item has been added; it is not a successful final submission and does not
make the version's Store metadata freely editable.

The journal records each submission write intent, confirmed submission/item IDs,
and a sanitized diagnostic. After interruption, status only reads Apple. For an
unambiguous existing draft whose final submit has not been attempted, it can return
`resumableSubmissionId`. To continue the same authorized release, call `submit`
with the unchanged `operationId`, `accountKey`, `confirmationDigest`, `confirm: true`
and `resumeSubmissionId` equal to that result. Identity, content, media order, build,
release mode and readiness are rechecked. Continuation fills only missing saved
app/product items in that exact owned draft before verifying and sending the
complete set. No new submission, unselected item, metadata edit, release-mode
change or journal reset occurs.
Legacy incomplete operations additionally expose
`requiresLegacyRecoveryConfirmation: true`: their old journal cannot establish
whether the final submit was attempted. `confirmLegacyDraftRecovery: true` is
required and asserts separately documented evidence of a pre-submit interruption,
such as the proven 1.0.69 READY_FOR_REVIEW guard failure. The draft's state alone
does not establish that history. This evidence assertion does not expand the
user's existing authorization. Ambiguous or unrelated drafts and uncertain
final-submit responses remain blocked.

Programmatic status remains read-only regardless of resumability. A successful
read is not permission to submit, and a historical completed submission cannot
establish success for a newly prepared draft. Apple must confirm the same draft
and the complete selected app/product set in an actual review state.

### Authentication capabilities

The browser and CLI share the pinned ASC implementation. Browser import validates
the candidate separately and preserves a valid richer CLI session, without merging
cookies from unrelated sessions. Its receipt distinguishes App Store Connect from
Developer Portal access; neither is proof of accepted agreements. The normal login
requires ASC access only. `asc_web_auth(requireDeveloperPortal: true)` additionally
opens the Portal when that specific capability is needed. After login rerun the
original scoped readiness check. Do not log out a healthy session or use manual
session exports as routine recovery.

## Readiness diagnostics

`validate` returns `validation.ready`, `blocking`, `warnings`, `unverified`,
`checkIDs`, and structured `diagnostics`. Each diagnostic includes `id`, `status`,
`source` and `reason`, with optional `locale` and `guidance`. Statuses distinguish
confirmed blockers from checks that could not be verified; an unknown status is
not reported as an inactive contract. The diagnostic fields contain sanitized
check results, not raw review data or Apple session material.

The current policy verifies the complete version history for the chosen platform.
What's New is not applicable to a verified first publication, even if its draft
number is above 1.0 or an earlier first submission was withdrawn. After a verified
publication, missing release notes remain blockers for the affected locales.
History from another native platform does not establish that this platform has
already published an app. Missing or unknown history stops validation rather than
guessing first-release status.

Apple Developer Program License, free-app business agreement and paid-app business
agreement are separate checks. Healthy business agreements do not prove that the
Developer Program License is current. Web evidence must belong to the exact app
and provider; unavailable authentication, unresolved teams/providers or unknown
agreement status remain `unverified` and prevent submission. Where applicable,
`guidance` names the next check or required login/Account Holder action. Blitz does
not accept legal agreements automatically. Known Apple agreement blockers remain
blockers even when a different endpoint appears healthy.

Warnings that remain relevant under strict validation count as blockers. Both
confirmed blockers and unverified required checks make `ready` false. Refreshing
authentication or correcting metadata permits revalidation of the same unchanged
operation; changed content/builds need a newly prepared snapshot. An interrupted
write still follows the separate status/reconciliation rules above.

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

### Stable purchase review-image identity (build 80)

Apple can rotate the `assetToken` returned for an unchanged completed IAP or
subscription review screenshot. When `sourceFileChecksum` contains a verified
nonempty checksum, the release fingerprint uses that checksum and retains the
resource ID, file size and remaining semantic attributes, but excludes the
rotating token. A changed checksum or resource still requires fresh preparation.
Assets without a usable checksum keep their token in the fingerprint so their
content identity is not silently discarded. This does not relax delivery-state,
product ownership, exact-selection or final-submit guards.

### Selected IAP readiness notices (build 81)

An explicitly selected, fully verified IAP in `READY_TO_SUBMIT` is expected
before the joint draft is sent. Its exact `iap.review_readiness.needs_attention`
warning can therefore be recorded as passed only when fresh product evidence
and the warning's resource type, resource ID, state field, severity and status
message all agree. This is not a global warning waiver: unselected products,
missing product evidence, other or unknown lifecycle states and changed warning
shapes remain blocking. The evidence is recalculated during validation and does
not alter the content fingerprint or allow a changed selection.

## Resubmit an updated, previously rejected review

A Resolution Center reply and an update to the review notes are not a new
submission. Apple can answer information-only requests in the existing thread.
If the rejected item is explicitly updated for review in App Store Connect,
`READY_FOR_REVIEW` means prepared, not sent; the enclosing review may still be
`UNRESOLVED_ISSUES` and retain its original submission date.

Use `prepare-resubmission` with the acknowledged original `operationId`, original
`accountKey`, and exact `submissionId`. It reads Apple, preserves the old journal,
and records a fresh confirmation operation with the same app, platform, build,
release mode and exact selected product versions. Current protected content gets
a new digest. Preparation performs no Apple writes.

If rejected items still need updating, first verify that their actual issues have
been corrected and that the user authorized continuing this exact release. Pass
`"resolveRejectedItems": true` to include their exact review-item IDs in the plan.
Without this option, rejected items remain blocked. Inspect the returned binding:
a reply alone is never evidence that an issue was fixed, and the option is not a
readiness waiver. Accepted siblings remain untouched. Unknown, foreign, missing,
removed or ambiguous items fail closed.

Run `validate` and explicitly confirmed `submit` on the new operation/digest.
Submission rechecks identity, content, mode, readiness and the complete item set,
marks only planned rejected items resolved, verifies their resulting states, then
sends the same review. It cannot create another review, replace the build or add
items. Report current `reviewOutcome`, `nextAction`, `appleState`, `submissionState`
and `submissionItemStates`; historical `state: submitted` is not current success.
`READY_FOR_REVIEW` means prepared but unsent. Confirm the same enclosing review
has reached a submitted state before reporting resubmission.

After uncertainty use `status`. Only `resumableResubmissionId` explicitly permits
continuing the same confirmation operation via `submit.resumeSubmissionId` and
its unchanged digest. It proves the earlier attempt stopped before final send;
an uncertain final-send outcome remains read-only and must never be replayed.
The ordinary unsubmitted-draft recovery path remains separate.

Apple documents the item-update and final resubmission steps in
[Manage a submission with unresolved issues](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/manage-a-submission-with-unresolved-issues).
This differs from replying to an information-only request without updating the
review items; use the action actually requested or already initiated by the user.
