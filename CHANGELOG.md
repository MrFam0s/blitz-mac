# Changelog

## 1.0.81 (build 101)

- Importing or creating an app installs the project simulator skill for Codex
  and Claude Code. Existing registered projects receive it when Blitz starts.
- App chats use the project's simulator for iOS and iPadOS tests, UI interaction
  and full-resolution screenshots. Native macOS targets use the Mac.

## 1.0.80 (build 100)

- Use a project’s selected iPhone or iPad simulator in Blitz. On iPhone Duo,
  change the fold position and interact with the active display in a flat preview.
  The camera button saves a full-resolution PNG.
- App chats can request a Duo pose and capture the active, outer or inner display.
  The screenshot preview and touch coordinates follow the orientation of that display.
- Import outer and inner screenshots into one iPhone Duo set per Store language.
  Blitz validates the four native sizes and keeps same-named images separate.

## 1.0.80 (build 99)

- Sort dashboard apps by name, status or date in either direction and remember
  the selection. Dates use changes observed by Blitz, falling back to the newest
  version draft's creation date; unknown dates remain last.
- Label each dashboard entry with its known platforms, distinguishing macOS,
  iOS and shared Store listings without combining separate app records.
- Keep dashboard rows in place while refreshing. Show names, platforms and status
  in a compact grid with direct controls for sorting and reversing the order.
- Add a color dot after each dashboard status and a size slider for app icons
  and text. Icons start at 56 points and the dashboard remembers the chosen size.
- Group dashboard apps by platform with a shared sort order inside each section.
  Apps that support both iOS and macOS appear once in their own section.

## 1.0.79

- Update the shared ASC app/CLI helper from 6.6.1 to 7.2.0, retaining the Blitz
  protocol adapter and selected-account binding.
- Adapt readiness and session import to ASC 7 and prevent inherited token
  commands or web brokers from overriding the app account.
- Publish build 94 as a regular Apple Silicon DMG, including the login recovery,
  complete review communication and guarded resubmission fixes from 1.0.76–1.0.78.

## 1.0.78

- Distinguish App Review replies, corrected review items awaiting resubmission,
  and a confirmed queued review. Keep undated drafts visible and show incomplete
  review data as unverified.
- Prepare and confirm exact rejected-item corrections through the shared native,
  CLI and MCP release workflow, then resubmit the existing review. Preserve
  accepted items, app/build identity, product selection and the original journal.
- Remove duplicate overview submission actions and explain the remaining step
  consistently in German and English. Update the bundled release skill.

## 1.0.77

- Show app-wide App Review messages even when Apple provides no version marker.
  Keep unassigned conversations separate from confirmed version/platform matches.
- Read Apple's version relationships and distinguish reviewer messages from
  developer replies. Recover this metadata from existing local archives.
- Preserve cached messages during refresh failures and provide explicit refresh
  and App Store Connect actions instead of incorrectly reporting no feedback.

## 1.0.76

- Keep the Apple sign-in page visible and interactive while it loads. Report
  stalled page loads or browser callbacks instead of waiting indefinitely.
- Reload the login window without deleting its saved browser authentication.
  Ignore late callbacks after cancellation, reload or a browser-process crash.
- Switching accounts opens a fresh isolated browser store immediately; delayed
  cleanup cannot erase the new account's cookies or block the new login.

## 1.0.75

- Allow an explicitly prepared resubmission after App Review corrections through
  the shared release CLI and MCP workflow. Reuse the existing review and its exact
  app, build and purchase/subscription selection; preserve the original journal.
- Distinguish the previously acknowledged submission from the current Apple
  review state. Unknown final-send outcomes still require read-only reconciliation.
- Publish build 90 as a regular, signed and notarized Apple Silicon DMG release.
  Updates are installed manually from the DMG; the legacy in-app updater does
  not install this format.

## 1.0.74

- Support German and English, selected automatically from macOS or in Settings.
- Recognize modern Xcode JSON5 projects and distinguish app targets from tests,
  frameworks and extensions while preserving Bundle-ID spelling and case.
- Simplify app identity selection and unify import, setup and release dialogs.
- Inspect project paths only after confirmation, avoiding scans while typing.

## 1.0.73 — first Blitz Neo public preview

- Share the maintained AmoSystems fork as an Apple Silicon download with its
  own identity, interface, CLI/MCP release workflow and project-specific simulators.
- Submit app versions together with explicitly selected in-app purchases,
  subscriptions and subscription-group metadata, preserving exact selection and
  recovery of existing review drafts.
- Stabilize review-image fingerprints against Apple's rotating download tokens
  and recognize fully verified selected purchases that are ready for submission.
- Prepare a signed drag-and-drop DMG instead of running the legacy installer.
  The download does not install simulator runtimes or change Xcode selection.
- Enforce the declared minimum macOS version for bundled native binaries and
  include dependency license notices in the application.
- Refresh public documentation and contribution instructions. The detailed
  changes between the earlier fork builds and this preview are in MAINTENANCE.md.

## 1.0.42 (maintenance fork)
- Bundle a pinned, tested iPhone MCP maintenance package instead of installing npm latest.
- Isolate simulator IDB connections, confirm completed inputs, bound failures and release helpers on disconnect.
- Require explicit selection among multiple booted simulators; exclude Xcode 27 simulated devices from physical-phone discovery.
- Use actual simulator dimensions and the maintained companion for screenshots and UI scans.
- Respect German and US simulator keyboard layouts, including German umlauts; reject unsupported text before sending any input.

## 1.0.41 (maintenance fork)
- Open the selected simulator in Xcode 27 Device Hub, while retaining the legacy Simulator launch path for older Xcode installations.
- Use the actual Device Hub screen bounds for capture and touch coordinates, excluding its top and bottom controls.
- Show permission settings only for the relevant screen-recording or accessibility failure.
- Restrict GitHub jobs to free public standard runners, without Actions artifact uploads or Go caches.

## 1.0.40 (maintenance fork)
- Run Swift regressions, ASC transport/protocol/CLI checks, and a verified release bundle on maintenance pushes and pull requests.
- Remember each project’s simulator, start it only when needed, and preserve running devices when switching or quitting Blitz.
- Bind simulator capture to the selected device; reject ambiguous windows instead of displaying another device.
- Show dashboard refresh failures, partial status failures, saved-data age, and retry/settings actions.
- Preserve cached statuses on failed requests and ignore results from obsolete account or project requests.
- Fix resource discovery under Swift Testing and portable ASC source extraction.

## 1.0.39 (maintenance fork)
- Remove the three-dot menus from dashboard app cards; Remove and Restore remain available by right-clicking each card.
- Hide automatic keyboard focus effects in the SwiftUI interface while keeping keyboard navigation available.

## 1.0.38 (maintenance fork)
- Remove apps from My Apps through their menu without deleting local projects or App Store Connect records.
- Keep hidden apps hidden across refreshes and restarts; restore them through Undo, Hidden Apps, or an explicit re-import.
- Search the dashboard by app name or bundle ID, with clearer app labels and accessible card actions.
- Show local projects even before ASC apps load or when the ASC account has no apps.
- Keep dashboard actions in a footer so they do not cover app cards; overview counts exclude hidden apps.

## 1.0.37 (maintenance fork)
- Build the embedded ASC helper against official ASC 5.15.0, sharing that version with Blitz's CLI wrapper.
- Retain Blitz's JSON-lines protocol and full HTTP responses while applying current upstream target validation and redirect protection.
- Respect globally configured Blitz MCP servers without rewriting project-level Codex settings.
- Pin and verify the ASC source/version in the build, with retained license and provenance.

## 1.0.36 (maintenance fork)
- Remember Apple sign-in browser state and provide an explicit account-switch reset.
- Stop logging login cookie value fragments and account email addresses.
- Handle gzip-encoded Apple web API responses in embedded ASC skills.
- Avoid duplicate external agent launches while preserving retry after failure.
- Repair stale test fixtures and support an explicit Swift build engine override.
- Use this fork as the update source. See MAINTENANCE.md for build and signing limitations.

## 1.0.35
- Blitz now detects all of your apps in App Store Connect and imports them into the dashboard, no more manual bundleID setup for existing projects. 
- Screenshot tab has been greatly simplified 

## 1.0.34
- Security updates
- Onboarding Improvements
- Simplified UI: Merge app details and store listing tab into one

## 1.0.33
- Fixed codex breaking in built-in terminal
- Show Review messages only when the attached version is selected in Overview tab
- Lots of bug fixes
- Minimal usage analytics to improve Blitz - no personal info whatsoever logged

## 1.0.32
Features
- Live gesture visualization overlays to see agents tap/swipe on simulator
- Automatically discover bundle IDs when importing projects already on App Store

Bug fixes
- Improved release version selection/update flow by ignoring stale historical versions when choosing defaults
- Improved imported project metadata/icon hydration and local blitz-iphone MCP command resolution

## 1.0.31
- New App Wall showing average review time, rejection ratio, and # rejects until success
- Version-aware ASC release workflow with create/update flow and unified version picker
- Better ASC diagnostics, fetch resilience, and project switching reliability
- Dashboard and app grid polish, plus improved launch logging

## 1.0.30
- New built-in terminal 
- New Dashboard and App navigation
- Project switching performance improvements
- Share ASC auth between asc-cli and Blitz MCP tools  
- Improved release/update reliability and simulator behavior
- Localization fixes (screenshot, store listing, overview tab)

## 1.0.29
- Faster App Store Connect setup with improved onboarding, credential entry, and bundle ID guidance
- Better review workflows with rejection feedback in Overview and Review, plus a submission history timeline
- More reliable ASC automation: pricing fixes, auth/session handling, screenshot support, and terminal fallbacks
- Release pipeline improvements including Intel builds, leaner packaging, and better Codex/MCP project setup

## 1.0.26
- ASC CLI skills: auto-provision 21 App Store Connect skills into each project's .claude/skills/
- Auto-install asc CLI if not present on the system
- Fix Apple ID email not captured during auto-create flow (sync XHR + ephemeral URLSession fallback)
- Auto-create via Claude Code now cd's into project dir so skills are discovered
- Fix shell injection in Terminal launch for auto-create flow

## 1.0.25
- Add App Store rejection feedback 
- Screenshot track-based workflow: arrange, reorder, and sync screenshots to ASC
- Paginate in-app purchases and subscriptions (up to 200 per page)
- App store review agent for Claude Code available in Blitz projects
- New MCP tools: screenshots_add_asset, screenshots_set_track, screenshots_save, get_rejection_feedback

## 1.0.24
Mac App Support! Now you can import or create macOS applications and upload to the App Store. 

## 1.0.23
- Improve auto-update UX: faster dialog, indeterminate progress, no admin prompt

## 1.0.20
- Better instructions for App Store Connect API key generation

## 1.0.19
- Hardcode FPS to 50

## 1.0.18
- MCP tool bug fix

## 1.0.11 
- Clear TCC bug fix

## 1.0.10
- Simulator bug fixes and pkg script fix

## 1.0.9
- Fix MCP bridge dropping responses when Claude Code sends notifications (root cause of asc_fill_form hanging)
- Fix App Store build for Xcode 26 (manual distribution signing, export method "app-store")
- Add early guard when provisioning profile is missing from app_store_build
- Fix MCP server rejecting notification messages that have no JSON-RPC id
- Add --max-time to bridge script curl to prevent silent hangs
- Add RN project template, remove warm-template logic
- Fix screenshot counts showing 0 in submission readiness
- Fix sidebar push caused by HSplitView in detail views

## 1.0.8
- Test Auto Update UI fix
## 1.0.7
- Auto Update UI fix 

## 1.0.6 
- Test Auto-Update Logic 

## 1.0.5
- Bug fixes

## 1.0.4
- Bug fixes

## 1.0.3
- Fix app crash on launch caused by Bundle.module failing to locate SPM resource bundle in .app
- Add auto-update: app checks for updates on launch and can download/install in-place
- Embed pkg-scripts in .app bundle for auto-updater to run postinstall on update

## 1.0.2
- Initial release of blitz-macos: native Swift rewrite of Blitz
