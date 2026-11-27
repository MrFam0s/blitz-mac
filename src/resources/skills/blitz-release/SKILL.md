---
name: blitz-release
description: Prepare, verify and submit App Store releases through Blitz Neo, including selected In-App Purchases and subscriptions. Use for "Update einreichen", a release handoff, Store localizations, preview videos, storefront availability, or missing age-rating or mainland China declarations on a prepared build.
---

# Release an app with Blitz Neo

## Short update request

An explicit request such as **„Update einreichen“** means preparing and testing
this project's next appropriate update, building/uploading the exact artifact,
preparing truthful release notes and submitting through the **Blitz Neo CLI**.
Use `AFTER_APPROVAL` by default unless the user or an explicit release policy
specifies another mode. Preserve an explicitly configured manual/scheduled release;
the CLI supports only `MANUAL` and `AFTER_APPROVAL`. A preparation-only request
does not authorize submission. These stored instructions alone authorize nothing.

Read `~/.blitz/bin/blitz-neo release --help` first. Help and standalone `asc`
commands work with Blitz Neo closed. When a release command needs the local
service, the CLI checks whether Blitz Neo is running. It reuses the running app
or starts it if closed, then waits for the socket before sending the request.
Let the CLI handle startup when the task reaches that command.
Prefer this CLI even when a chat has an old MCP tool list; never fall back to raw ASC/API
submission to bypass a missing capability or a blocked check. Use the shared ASC
CLI for builds, uploads and metadata, and the Blitz CLI for the final workflow.
If the intended release is currently waiting for review, in review or approved,
reconcile/report its current state instead of
creating another update. Ask only about a genuinely ambiguous target, missing
product fact or requested change of scope, not to reconfirm this same authorized
submission after discovering its exact version/build.

Use the existing development chat when available. The embedded Blitz terminal and
an external chat use the same project facts, target identity and release operation.
This skill supplies procedure, **not permission** to upload, change Store records,
submit or publish. Follow the user's actual request; an explicitly authorized Blitz
release handoff already supplies its stated scope and does not need to be confirmed
again. Copying or reading an old handoff does not authorize a different release.

Creating a new App Store record is a separate operation. Use the confirmed identity
handoff and `asc-app-create-ui` for that step; its successful completion does not
authorize submitting the first version.

For an authorized resubmission or review continuation of the same build, route
to "Updated review after an acknowledged rejection" before ordinary new-version
or build preparation. Historical `state: submitted` is not proof of current review,
and `READY_FOR_REVIEW` is prepared but unsent. Do not replace the version/build
or create another review merely because the ordinary editable-state gate fails.

## Establish the target and product facts

Read applicable project instructions, `docs/blitz-product.md` when present, and any
handoff's immutable target. Without a handoff, establish the target from this
project's registered Blitz metadata, Release build settings and a read-only Apple
lookup; do not require a new chat or a prior dashboard-button click. Verify facts
against the current source and actual build.
Chat history includes plans and abandoned ideas; do not turn those into Store claims.
Keep supported features, limitations, platforms, external services, privacy facts,
test evidence and public URLs in that project document. Preserve authored text.
Unfilled sections mean unknown. Ask only for facts that cannot be established from
the project; do not infer privacy, rights, encryption or demo-login answers.

Keep project path/ID, Apple account, app ID, case-sensitive bundle ID, platform,
version ID and eventual build ID together. A dashboard selection is not identity.
Discover the configured targets with `~/.blitz/bin/blitz-neo release targets
--request <JSON-file>` and a request containing the explicit `projectId`. This
reads only local registration; verify the returned Store binding against Apple.
Use one `releaseTargetId` throughout the workflow. When several targets exist,
choose the one named by the user's platform/scope; ask if ambiguous. The current
UI selection is never a default for an external release. The compatible single-target
case, including an ordinary first import, resolves to `legacy`; new operations still
record that explicit ID. It may lack a saved binding, but exact live account/app/bundle
verification remains required. Additional targets need verified Store registration
before release preparation.

Native iOS and macOS versions may share one Store app ID, while separate products
may have distinct app IDs or bundle IDs. Preserve each configured binding and its
build scheme. Never infer a second app record from a different platform, rewrite
a bundle ID, share version/build numbers, or reuse the other platform's changelog
without checking its actual changes. One operation releases one target. A request
covering both platforms needs separate scoped operations, builds and validation;
success for one is not success for the other.

Use `get_release_context` with the explicitly intended project/app IDs and compare
its returned target with the handoff before using UI-bound MCP tools. Include the
same `releaseTargetId` for multi-target projects. Supply the
unchanged `expectedTarget` required by those tools; if selection or account changes,
stop that operation rather than capturing and adopting the new selection.
Use separate explicit IDs for new versions/builds returned by verified operations.

The installed `asc` CLI shares Blitz's implementation and authentication. Read its
current `--help`. Pass explicit app, platform, version and build identifiers instead
of relying on defaults such as the newest version/build. Do not create another ASC
installation or export keys/session cookies. Renew required web authentication
through Blitz; a successful login is not evidence that a Store write succeeded.
Keep a working CLI session. Do not routinely log out or repeat browser login.
App Store Connect and Developer Portal authentication are separate capabilities:
for a diagnosed Portal authentication gap use `asc_web_auth` with
`requireDeveloperPortal: true`, then rerun the original readiness check. An ASC-only
login does not prove program-license status. Do not export cookies, overwrite the
session cache, or treat any authentication receipt as legal-agreement acceptance.

## Store changes through Blitz Neo

If a previous submit has an uncertain outcome, reconcile the original operation
with `blitz-neo release status` before changing any Store data. While the final
send remains uncertain, continue read-only.

For previews, storefronts and mainland China declarations, use the dedicated
`blitz_macos` tools when exposed in this chat. Use the original `accountKey` and
`operationId` for an existing release. Before preparing a release, use `accountKey`
and an explicit registered `target` from `get_release_targets` with projectId,
releaseTargetId, appId, bundleId and platform; previews also require versionId.
Inspect the live tool schema. A write requires authorization for that operation
and `confirm: true`. Apple requests run inside Neo. Each integration retains its
own access controls; respect any denial covering the intended action.

Use the bundled `~/.blitz/bin/asc` for other supported Store operations or when a
dedicated tool is unavailable and the CLI has access. Its Apple requests use HTTPS. The separate
`~/.blitz/bin/blitz-neo release` client connects to the running app over a
local socket. Diagnose the failing command and destination independently.
If the host blocks app launch, local socket access or the Apple network request,
request access for the exact command that requires it (in Codex,
`require_escalated` with a reason naming the app, destination and read or write).
A socket permission error can occur while Blitz Neo is running. Leave the
running app in place. Retry a read once access is granted. If a Store write
may have reached Apple, read back before retrying. If a final submit may
have been sent, use only `release status` on the original operation.
For an Apple HTTP response, address the reported authentication, role or
validation error. If an access request is explicitly rejected, respect its
scope and report the failed step and what remains verified. A browser login,
Computer Use or switching terminals cannot grant that permission. Ask for
login only when the required Apple operation actually reports an authentication
problem. Network permission and authorization to change a Store record are separate.

- **Store texts and missing languages.** Pin the app ID, editable app-info ID,
  platform and marketing version. Pull current localizations into a fresh
  staging directory, preserve every existing locale, then overlay only the
  authorized app-info and version text. Run
  `asc metadata push --app APP_ID --app-info APP_INFO_ID --platform PLATFORM --version VERSION --dir STAGING_DIR --include localizations --dry-run`.
  This reads Apple and shows the planned additions and edits. If the plan
  matches the requested languages and fields, apply the same command without
  `--dry-run`. Do not enable deletes to make a partial directory pass.
  Pull into another fresh directory to verify both app-info and version texts.
- **Preview videos and poster frames.** Call `store_previews_list` for each exact
  locale and Apple device type (`DESKTOP` for macOS). Send `store_preview_upload`
  the project-relative file and optional `posterTimeCode` (`00:00:06:00` for
  second six). Inspect the receipt and read the same set again. While Apple
  processes a video, monitor its existing ID. For a missing or changed poster
  use `store_preview_set_poster` on that ID. Report the confirmed poster and
  processing state separately. The CLI equivalents are `asc video-previews list`,
  `upload` and `set-poster-frame`.
- **Storefront availability.** Use `store_availability_get` to compare the selected
  countries with Apple's current catalog. To apply an authorized change, use
  `store_availability_set` with explicit `territoryCodes` or
  `allCurrentTerritories: true` and the intended `available` flag. First setup
  also needs an explicit choice for `initialAvailableInNewTerritories`.
  Preserve the existing future-country policy on later edits. Re-read the full
  selection after a partial or uncertain result before considering another change.
  The CLI provides `asc pricing availability territory-availabilities --app APP_ID --paginate`
  and `asc pricing territories list --paginate` for comparison. Storefront selection
  alone does not establish that a version is on sale.

After Store edits on a prepared release, follow the same-build check below.

## Correct required declarations on a prepared build

Use the Store access procedure above. Reconcile an uncertain submit before writing.

- **Age rating:** Use `asc age-rating view --version-id VERSION_ID --fields sharedLocation,datingAndRelationships`
  on the bound version. An explicit `false` is an answer. For a missing answer,
  check the shipping features covered by the declaration. Within the authorized
  scope, use `asc age-rating edit --version-id VERSION_ID` with only the
  applicable flag(s), `--shared-location true|false` and/or
  `--dating-and-relationships true|false`. Read the fields back and compare
  them to the intended values.
- **Mainland China:** Use the [China mainland procedure](references/china-mainland.md)
  for `store_china_declarations_get` and `store_china_declaration_set` on the bound app and provider.
  Check each declaration separately. Keep the requested storefronts and reuse
  the existing web session when valid.

After readback, verify the original platform, version ID and attached build ID.
With a prepared, unsent operation, use `blitz-neo release validate` or the equivalent `release_validate` tool with the original operation and account. If Blitz
reports changed content (`needsPreparation`) before any submission attempt,
repeat `release prepare` with the **same target, version ID, build ID, mode and
reviewItems**, then validate the returned operation. This renews the local
confirmation without uploading a build. If a submission was attempted or an
Apple review draft is already associated with the operation, read `release status`
first and follow its draft-continuation instructions below. Report the verified
build and remaining blockers.

## China mainland

Check the app's selected storefronts and the release request before filing.
For a selected or explicitly planned `CHN` release, follow the
[China mainland declaration procedure](references/china-mainland.md) during preparation.
Resolve `AI_GENERATED_CONTENT` and `SECURITY_ASSESSMENT` independently from
the features actually offered there. Reuse evidenced answers and permits for the
same provider and app, including evidence recorded in existing project documents.
Skip the CHN procedure when the storefront is confirmed excluded and the request
does not include it. Keep an unverified territory selection open until resolved.

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

## Include purchases and subscriptions when in scope

If this release includes purchases or subscriptions, read the bundled
`asc-iap-attach` skill. Establish the exact authorized metadata-version resources,
including any required new subscription-group version. Parent product IDs are not
review-version IDs. An app update does not implicitly include every pending
product. Prepare product metadata, review screenshots, pricing and availability
within the authorized scope before the final workflow. Keep a list of selected
resource types/IDs and their parent product identities in the private release
report; the CLI requires only the exact version type/ID pairs.

## Final guarded workflow

Once the build is attached and the Store content is ready:

1. Run `~/.blitz/bin/blitz-neo release prepare --request <JSON-file>` with explicit `projectId`, canonical `projectPath`, `appId`,
   `releaseTargetId`, exact `bundleId`, the target's supported `platform` (`IOS` or `MAC_OS`), the original nonsecret `accountKey`
   (`issuerId:keyId`), `versionId`, `buildId` and the requested `releaseMode`
   (`MANUAL` or `AFTER_APPROVAL`). For a joint release, also pass explicit
   `reviewItems: [{"type":"inAppPurchaseVersions","id":"VERSION_ID"}]`, using
   `subscriptionVersions` and `subscriptionGroupVersions` for the other kinds.
   Omit it or use `[]` for app-only; the app version is always implicit. At most
   199 unique additional versions fit one operation. This reads Apple
   state and creates a private operation; it does not submit. Preserve its operation
   ID, immutable target (including its exact `reviewItems`) and confirmation digest in the private release report.
2. Run `~/.blitz/bin/blitz-neo release validate --request <JSON-file>` with its `operationId` and original `accountKey`. It checks fresh scoped Store readiness
   and the saved content snapshot. These checks supplement, not replace, functional
   app tests and the reviewed product facts. Resolve blockers within the user's
   scope. If the intended content/build changes, prepare and validate its new
   snapshot; never edit a saved operation or reuse an old confirmation digest.
3. If submission is already authorized for this exact release, run `~/.blitz/bin/blitz-neo release submit --request <JSON-file>`
   with that `operationId`, original `accountKey`, `confirm: true` and the current
   `confirmationDigest` returned by validation. For an explicit preparation-only
   request, stop and report the prepared result without asking to submit. Otherwise present the
   concrete version/build, changes, checks and release mode before asking for the
   missing authorization. A returned digest is evidence of a snapshot, not permission.
4. Run `~/.blitz/bin/blitz-neo release status --request <JSON-file>` with `operationId` and `accountKey` to reconcile and report Apple's actual status. The operation
   records the submission boundary durably. After timeout, interruption, account
   change or an uncertain response, query status; do not replay submission through
   ASC or create a new operation to bypass an unresolved attempt.

## Updated review after an acknowledged rejection

A historical `state: submitted` does not prove that Apple is currently reviewing
an updated submission. Inspect `appleState` and `submissionState`. A Resolution
Center reply is not a new submission. For information-only requests, follow
Apple's requested response path; do not resubmit merely because the status has
not changed. If the user has explicitly updated rejected items for review, verify
the existing submission and all its selected items before continuing.

For the same already authorized app/build and selected product versions, use
`blitz-neo release prepare-resubmission --request <JSON-file>` with the original
acknowledged `operationId`, original `accountKey`, and exact `submissionId`.
This reads Apple and creates a fresh confirmation operation/digest for the same
complete item set. It preserves the old journal and performs no Apple writes.
If any selected review items remain rejected, verify their actual corrections
first and use `resolveRejectedItems: true` only when the user authorized their
resolution and resubmission. Inspect the exact item IDs recorded in the plan.
A message reply never proves resolution; never mark uncorrected issues resolved.
Accepted siblings are preserved, not resent as changed items. Missing, unknown,
removed, foreign or ambiguous items remain blocking.

Validate and explicitly submit the returned operation with its fresh digest.
This resolves only planned rejected items, verifies their states and resubmits
that same review. It never creates a replacement review, resets the journal or
changes build/product selection. Existing authorization persists for unchanged
scope; a different app/build/product set needs a new scoped plan.

Report `reviewOutcome` and `nextAction` alongside current Apple/submission/item
states. Historical `state: submitted`, a reply, and `READY_FOR_REVIEW` are not
proof of a newly queued review. After uncertainty read `status`. Only an explicit
`resumableResubmissionId` allows continuing that same confirmation operation with
`resumeSubmissionId`, its unchanged digest and `confirm: true`; it proves a safe
pre-final-send boundary. An uncertain final submit permits status only, no replay.

If Apple has saved previously missing age-rating answers, run `release status`
on the original operation. When it returns `refreshableSubmissionId`, verify
the reported `ageRatingCorrection` (including explicit `false` values) against
the app's features and the authorized correction. Run
`release prepare-draft-refresh --request <JSON-file>` with the original
`operationId`, `accountKey`, old `confirmationDigest` and the returned draft
ID as `submissionId`. Check the returned answers and validate the same operation
again. For an authorized submission, continue with the new digest and the
exact draft ID as `resumeSubmissionId`. If the evidence or authorization is
missing, report what still needs verification. Never infer answers from an empty field.

If Apple rejects adding the app version or a product to the draft with HTTP 409,
run `release status` and follow `validateDraftContinuation` on that operation.
A resumable draft ID identifies the draft. Review the fresh validation before
continuing. For `compliance.CHN.ai_generated_content` and
`compliance.CHN.security_assessment`, check the storefront selection and the
two individual results. An HTTP 409 without a field pointer does not identify
its cause. Use the China mainland procedure above for an outstanding declaration.
Revalidate the same operation and draft after recording the answer.

If `status` returns `resumableSubmissionId`, it has identified a unique existing
unsubmitted draft for this same operation. Verify that ID against the saved release
evidence. For this already authorized, unchanged release, use the same `submit`
request with **`resumeSubmissionId` set to that exact ID**, keeping `operationId`,
`accountKey`, `confirmationDigest` and `confirm: true`. This is the explicit
continuation path: the backend rechecks target, content, build, release mode and
readiness, adds only missing saved app/product items to that same owned draft,
then sends its exact complete set. It does not create a new submission, add
unselected products or reset the journal. Without a resumable ID, or after an uncertain final submit,
stop at read-only reconciliation. Never hand-edit a journal or guess a draft ID.
Old journals without write phases additionally report
`requiresLegacyRecoveryConfirmation: true`. Supply `confirmLegacyDraftRecovery: true`
only when the saved incident report or trace proves the old run stopped before
its final submit. A current draft state alone is insufficient. This assertion
confirms that documented evidence was checked; it is not a new release authorization. The original authorization
still applies to unchanged scope. With an unknown old final-submit outcome, stop.
`READY_FOR_REVIEW` means a draft exists but has not been submitted; require the
same draft, app version and exact selected product versions to reach a submitted review state before
reporting submission. A historical `COMPLETE` submission is not proof that the
current draft was sent.

Write request JSON with a serializer and quote the actual absolute file path;
`<JSON-file>` above is a placeholder, not a shell expression. Stdin is also
supported via `--request -`. The equivalent MCP tools use the same backend, but
this project's default route is the CLI. `release context` accepts `projectId`
and `appId`, plus `releaseTargetId` when several targets exist, and verifies the current UI target when UI-bound tools are needed;
the final prepare/validate/submit/status workflow is independent of UI selection.
Do not invent commands or replace guarded final submission with direct ASC
because a check failed. Check the installed CLI help before reporting a missing capability.

An authentication failure during read-only preparation/validation can resume after
login with the same unchanged target. A failure after a write might have taken
effect; reconcile before any retry. App-creation retries follow their separate
stage-aware creation skill and operation journal.

Report app, exact version/build, source and artifact evidence, test outcome, remaining
blockers and verified Apple state. Distinguish “prepared”, “submitted for review”
and “published”. `AFTER_APPROVAL` means publication after Apple's approval, not an
immediate release. Do not change pricing, territories, tester groups or another app
unless the user's task specifically includes them.
