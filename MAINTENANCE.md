# Maintenance fork

This is a personal maintenance fork of [Blitz](https://github.com/blitzdotdev/blitz-mac), not an official successor. Upstream `master` remains available for comparison. The maintained branch is `maintenance/auth-and-tooling`.

## 1.0.36

- Retain Apple sign-in browser cookies in a persistent, app-specific WebKit store ([upstream PR 26](https://github.com/blitzdotdev/blitz-mac/pull/26)). Apple can still expire sessions or require 2FA. The first sign-in after this update establishes the persistent browser state.
- Offer **Use Another Apple ID** to clear that browser's state deliberately. Safari data is separate. Do not log cookie values or account email addresses from the login sheet.
- Decode gzip responses in the bundled ASC web API skills ([PR 29](https://github.com/blitzdotdev/blitz-mac/pull/29)).
- Suppress duplicate external agent launches while allowing immediate retries after failed launches ([PR 30](https://github.com/blitzdotdev/blitz-mac/pull/30)).
- Repair outdated test fixtures to match the existing model initializers.
- Point the updater at this fork so an upstream update cannot silently discard these fixes.

The larger screenshot redesign and the subscription-group feature PR are not included. The embedded ASC daemon and iPhone MCP are unchanged.

## 1.0.37

The embedded helper now builds from official ASC 5.15.0 with a small protocol
adapter maintained in this repository. The CLI wrapper and the app share this
ASC version. The iPhone MCP remains unchanged. When both Blitz MCP servers are
configured globally in Codex, Blitz preserves existing project settings and
does not generate duplicate local server definitions. Existing duplicates can
be removed from project TOML after checking the global settings.

## 1.0.38

My Apps now supports **Remove from Dashboard** in each card's menu and context
menu. This saves a visibility preference only; project files, import links and
App Store Connect records remain intact. **Undo**, **Hidden Apps → Restore to
Dashboard**, and an explicit re-import bring an app back. Visibility is stored
in `~/.blitz/dashboard-hidden-apps.json`, independently of the ASC cache.
Bundle/project identities preserve it when rows are refreshed or relinked.

The dashboard also searches names and bundle IDs, shows local projects without
requiring ASC results, and keeps its action buttons below the scrolling grid.
The overview counts describe visible apps, independent of the search text.
ASC remains at the version pinned by the previous update.

Validated with all 109 Swift tests and a signed release build. On the installed
app, a local-only project was removed, restored with Undo, removed again,
refreshed, and kept hidden through a full restart before being restored through
Hidden Apps. Bundle-ID search and both global MCP server handshakes also passed.

## 1.0.39

Dashboard cards now expose Remove/Restore through their right-click context
menu only, without a separate three-dot button. SwiftUI keyboard focus effects
are hidden in the main window while keyboard navigation remains available.
Validated with all 109 Swift tests, a signed release build, and the installed
app: Tab navigation no longer draws focus rings, and a local-only app can be
removed and restored using the right-click context menu.

## 1.0.40

`Maintenance checks` runs on pushes and pull requests targeting `maintenance/**`,
plus manual dispatch. It needs no Apple secrets and cannot publish or install a
release. It runs Swift tests, the pinned ASC transport/protocol/CLI tests, builds
an ad-hoc signed app, checks its signature and helper contract, and retains a ZIP
with its checksum only for the lifetime of that runner. The weekly ASC update
preparation is unchanged.

### GitHub: free services only

Use only free GitHub features for this fork. All workflow jobs require a public
repository and use standard `macos-15` or `macos-15-intel` runners; do not switch
to larger runners or run these jobs in a private repository. Go caches and
Actions artifact uploads are disabled to avoid additional cloud storage usage.
Builds remain available locally; CI records the checksum in its log.

Never add a payment method, increase a spending limit, enable paid reviews, or
purchase another service to unblock checks. A GitHub account billing restriction
can still prevent a free runner from starting. Report that limitation and use
the local test/build commands below. The weekly ASC updater must follow the same
rule. See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

Simulator choice is saved in each project's existing `simulatorUDID` metadata.
The dashboard and Store views do not boot devices. The Simulator tab starts only
that project's saved device; a project without a choice asks for one. Missing
choices are reported instead of silently selecting another device. Switching
projects, choosing another device and quitting Blitz leave simulators running.
Screen capture matches the selected device name and refuses ambiguous windows;
use unique names for project simulators with the same device model.

The dashboard shows the app-list timestamp, saved-data state, actionable errors,
and Retry/Settings. Partial status failures retain prior statuses with a warning
and mark affected cards; totals may then be stale or incomplete. Cached data from
a different account is never reused. Late and cancelled requests cannot overwrite
a more recent account or project selection.

Local checks:

```sh
swift test --build-system native
bash scripts/test-asc-helper.sh
BLITZ_ASCD_PATH="$PWD/.build/ascd-helper/ascd" BLITZ_SWIFT_BUILD_SYSTEM=native \
CODESIGN_TIMESTAMP=none bash scripts/bundle.sh release
python3 scripts/verify-asc-helper.py .build/Blitz.app/Contents/Helpers/ascd
```

## 1.0.42

The separate iPhone MCP now ships as a reproducible maintenance package,
`0.1.18-blitz.1`, from pinned upstream source plus the tested overlay in
[helpers/iphone-mcp-overlay](helpers/iphone-mcp-overlay/README.md). The bundle
contains this package and checksum. Installation stages dependencies, validates
the package and retains the previous tree; updates no longer install npm latest.
The existing global `blitz-iphone` entry and executable path remain valid.

Simulator input uses private companion sockets, bounded acknowledged CLI calls,
serialized requests and scoped cleanup. Failed or timed-out actions are never
replayed automatically. No global IDB kill or all-target discovery is used for
simulator input. Both subprocess environments and error messages exclude entered
text and credentials. Multiple booted simulators require an explicit UDID.
Xcode 27's simulated devicectl entries are excluded from physical-device discovery.
The companion supplies screen dimensions and UI scans, without assumptions about
simulator names or legacy ax-scan frameworks. String/numeric key sequences and
fractional touch coordinates are translated to the CLI's actual input format.
Text respects the selected simulator's active German QWERTZ or US QWERTY layout.
German umlauts are supported. Unknown layouts and unsupported characters fail
before any text is sent. No clipboard is used: Xcode 27's `simctl pbcopy` returned
success without copying in live verification. iOS autocorrection/smart punctuation
still apply to HID input; verify the field with `describe_after`.

Build the package before bundling to reuse it:

```sh
# Node 22 / npm 10 on PATH
bash scripts/build-iphone-mcp.sh
python3 scripts/test-iphone-mcp-installer.py
BLITZ_IPHONE_MCP_TARBALL="$PWD/.build/iphone-mcp/blitzdev-iphone-mcp-0.1.18-blitz.1.tgz" \
BLITZ_SWIFT_BUILD_SYSTEM=native CODESIGN_TIMESTAMP=none bash scripts/bundle.sh release
```

Existing running MCP sessions keep their loaded code until the client reconnects.
New sessions identify the maintenance version during initialize. Physical iPhone
control still uses the existing WDA implementation; simulator checks do not verify
physical-device behavior. GitHub must remain on free public standard runners.

### Local verification, 19 October 2026

- 131 Swift tests, 17 Node MCP tests, 7 Python keyboard tests and 5 offline
  installation transaction tests passed.
- Release bundle built and verified with the existing Developer ID; ASC 5.15.0
  JSON-lines and CLI contract checks passed without account access.
- Actual MCP stdio sessions against the installed package verified discovery,
  exact simulator targeting, screenshots, hierarchy/region scans, taps, swipe,
  Home, text, Backspace, mixed key sequences, ambiguous-target errors and clean EOF.
- German y/z, umlauts, eszett and common Option symbols matched the visible field.
  iOS smart quotes remain enabled. Unsupported emoji failed before any input.
- The owned temporary simulator was deleted. All twelve pre-existing simulators
  retained their names and states. No physical-device control was exercised.
- Global MCP executable/configuration paths are unchanged. Existing clients need
  to reconnect (restart Codex) because their already-loaded server code remains old.
- Installation extracts the staged package and runs `npm ci --omit=dev` against
  `npm-shrinkwrap.json`, then builds only the required native addon. Global npm
  installation was verified to resolve newer libraries and is no longer used.

## 1.0.43 — overview loading and saved metadata

Opening an app now restores its last overview and refreshes independent sections
as they arrive. Text does not wait for screenshot requests. Icon discovery runs
off the UI actor and skips dependency/build trees. Routine overview loads avoid
the full price-point catalog; submission still performs fresh readiness checks.

Store listing metadata is cached per ASC account and bundle ID in
`~/Library/Caches/com.blitz.macos/asc-overviews`. Entries expire after seven days,
are limited to 24 files of at most 2 MiB each, and use hashed filenames and private
file permissions. Review contacts, demo credentials, authentication material,
drafts, image bytes and tester data are excluded. Disk restores always revalidate;
in-memory project snapshots are bounded and normally refresh after two minutes.

Pending fields use loading indicators. Failed requests retain prior values and
show a retryable refresh warning instead of a red missing-field error. Confirmed
missing values remain visible as such. Cancelled requests from earlier project
or version selections cannot overwrite the current overview, and simultaneous
tab refreshes share one task. Submission preview checks current data before its
submit button can become available.

The ASC adapter overlaps at most four GET/HEAD requests. Mutations, session
changes and CLI calls retain ordered execution. The app and CLI still share
ASC 5.15.0; this update changes the adapter, not the pinned upstream version.
`BLITZ_BUILD_JOBS` optionally bounds Swift bundle-build parallelism.

Local automated validation: all 141 Swift tests, ASC transport/helper tests with
the complete CLI compatibility comparison, and helper concurrency tests under
Go's race detector passed. Fixtures cover slow screenshots, partial failures,
retry, project/version changes, account isolation, cache expiry/corruption and
entry-count limits. No Store mutations are used in these tests.

The Developer-ID-signed release bundle and bundled ASC protocol/CLI contract
passed verification. Installed UI checks covered Muehlenstein and Besser Lesen,
switching back, manual refresh and a full quit/restart. Both caches persisted
(about 50 KiB combined, mode 0600), and installed app/CLI helper hashes match.
During refresh/navigation, 129 read-only MCP probes that execute on the UI actor
had a median response of 3.24 ms and maximum of 97.62 ms. This is a local
responsiveness sample, not a network latency guarantee. Slow/failed-network
behavior is covered by controlled fixtures, without disconnecting the user's Mac.

## 1.0.44 — cached release and TestFlight tabs

App Information, screenshot metadata, Builds, Groups and Beta Info now restore
account/app-scoped disk snapshots before revalidating. Version-scoped listing
and screenshot data also require the selected version to match. The metadata
cache holds at most 120 entries, 2 MiB each, expiring after seven days. Successful
overview requests are shared with the information, screenshot and build tabs
rather than fetched again on first entry. Tabs show the saved-data timestamp.

Screenshot previews use a separate account/app/URL-scoped cache, limited to
128 MiB, 300 images and seven days. Preview requests are coalesced and each
hydration batch fetches at most four images concurrently. Tracks appear before
previews finish; unchanged images survive metadata refreshes. Original upload
files, unsaved tracks and editor drafts are not written into this cache.
Background refresh preserves edited text and screenshot ordering. Failed
screenshot baseline checks stop synchronization before any Store write.

TestFlight feedback remains in memory only, bounded to twelve builds per
project, with a two-minute freshness window. Failed refreshes retain existing
comments. The feedback reader now uses Apple’s app-scoped
`betaFeedbackScreenshotSubmissions` endpoint and decodes `createdDate`, `email`
and screenshot arrays; the previous nonexistent `betaFeedback` route returned
HTTP 404. Disk snapshots exclude tester feedback, tester addresses, review
credentials and authentication material. Metadata and previews use mode 0600
inside private cache directories. Late responses are rejected after project
or version changes; explicit refresh and normal edits remain available.

Validation: 157 Swift tests passed, including new scope/version, expiry,
corruption, size/count bounds, preview reuse/coalescing and URL invalidation, failed refresh,
unsaved screenshot preservation and late-response regressions. The ASC helper
and iPhone MCP implementations are unchanged from 1.0.43.

The Developer-ID-signed 1.0.44 release passed the release bundle build, strict
signature verification and bundled ASC protocol/CLI contract and was installed
locally. Live UI checks covered all five cached tabs, feedback, normal quit and
relaunch, and retaining an unsaved Beta Info draft across refresh (then restoring
it without saving). Twenty preview files were reused unchanged after restart.
The current build’s feedback query now confirms an empty result instead of HTTP
404. No Store mutations, uploads or device actions were performed. GitHub remains
restricted to the free public-repository workflow described above.

## Build and validation

### Xcode 27 / Blitz 1.0.41

The selected Xcode's Device Hub replaces Simulator.app on Xcode 27. Blitz resolves
the viewer from `DEVELOPER_DIR` or `xcode-select -p`, and opens the selected device
in its own compact window using Device Hub's registered `devices:///device/open?id=`
URL handler. This route was verified against the locally installed Device Hub;
it is not a guarantee of a stable Apple API. Older Xcode installations retain
the Simulator.app path and `-CurrentDeviceUDID` launch argument.

Device Hub's capture is restricted to the uniquely named selected device window.
Accessibility provides the actual device screen rectangle, excluding both its
header and bottom controls. Device Hub exposes host and remote accessibility
containers with equivalent screen bounds (within half a point); those count as one
screen, while different candidate rectangles remain an error. A newly opened
window gets a bounded layout retry; permission failures are not retried.
If permission or an unambiguous screen rectangle is
unavailable, Blitz reports the issue instead of sending incorrectly mapped
touches. Changes to Device Hub's accessibility hierarchy may require adapting
this integration. Only the affected permission offers a System Settings action.

On Apple Silicon with macOS 15+ and Xcode 26+, the installer now refreshes the
official IDB companion to **1.7.6**, including when Python's CLI already exists
and during app updates. `scripts/pkg-scripts/install-idb-companion.sh` pins the
release SHA-256, preserves the complete Resources tree and a backup of the prior
installation. Other hosts retain the legacy companion. This fixes the obsolete
1.1.8 companion's SimulatorKit path on Xcode 27. The existing Python client is
unchanged. A manual local app-copy installation can run the same helper script:

```sh
bash scripts/pkg-scripts/install-idb-companion.sh "$HOME/.blitz/idb-companion"
```

Blitz's IDB subprocesses receive only a small environment allowlist, because old
companions log their inherited environment. Agent and App Store credentials are
excluded. The Metal screen's input overlay uses a native AppKit event surface;
SwiftUI's drag recognizer did not deliver taps reliably above the Metal view.
The Simulator view starts a companion for the chosen simulator on its own private
UNIX socket. It does not reuse IDB's global connection cache or enumerate physical
devices; both caused startup failures during Xcode 27 verification. Concurrent
first inputs share one serialized startup. Leaving the view stops only its own
helpers; the pinned companion also exits after 60 seconds without requests.
Late input tasks retain their originating session and UDID and cannot restart a
closed session. A temporary invalid Device Hub AX tree during capture receives a
bounded retry with touches suspended; it does not immediately stop the image.

Validated locally on Xcode 27 with 131 Swift tests, three offline installer
checks, a release build, strict code-signature verification and the bundled ASC
protocol/CLI contract. The installed Developer-ID-signed release starts without
renewed permission prompts and accepts Settings taps and Home input. The full
UI pass also verified scrolling, resize with correct touch mapping, reopening
the selected compact window, and preserving selection across normal quit/reopen;
other simulators retained their names and running states.

The separately installed iPhone MCP package is unchanged. Its handshake was
checked, but device actions through that package and physical iPhones were not
part of this UI verification. Its automatic IDB discovery still uses the global
connection cache/all-target enumeration; the private simulator connection above
applies to the Blitz app only.

Initialize the pinned submodule and install Go as specified by its `go.mod`:

```sh
git submodule update --init --recursive
swift test --build-system native
BLITZ_SWIFT_BUILD_SYSTEM=native \
CODESIGN_TIMESTAMP=none bash scripts/bundle.sh release
```

The `native` build engine avoids requiring the optional Metal toolchain with Xcode 27. It is deprecated by Swift and is a local compatibility fallback; with the Metal toolchain installed, use the default engine. `BLITZ_SWIFT_BUILD_SYSTEM` is optional and does not change the default build engine.

Without `APPLE_SIGNING_IDENTITY`, the bundle is ad-hoc signed, not notarized. Existing Keychain or macOS permissions may require approval for the rebuilt app. The default build compiles the pinned ASC source with the Blitz adapter. `BLITZ_ASCD_PATH` accepts a prebuilt helper only if its protocol and pinned version match. See `helpers/asc-overlay/README.md` for provenance and Go tests.

For local installations, prefer the maintainer's existing personal Developer ID
Application identity via `APPLE_SIGNING_IDENTITY`. Keeping that signing identity
and bundle identifier stable lets macOS recognize subsequent builds. CI can
continue to use ad-hoc signatures without access to private keys. Signing alone
does not notarize the app; do not create, purchase, or export certificates as a
routine build step. A first switch from ad-hoc signing can need renewed consent.

When replacing the official signed app with a local build, macOS can retain the
original app's signing requirement even when Screen Recording appears enabled.
If the `tccd` log reports `Failed to match existing code requirement` for
`com.blitz.macos` and `kTCCServiceScreenCapture`, ask the user to remove the old
Blitz entry in Privacy settings, add `/Applications/Blitz.app` again, and approve
the current app before fully quitting and reopening it. Do not reset unrelated
apps' privacy permissions or claim that toggling the old entry necessarily fixes
the signature mismatch.

## One ASC implementation

Blitz installs its current helper at `~/.blitz/bin/ascd` and a CLI wrapper at
`~/.blitz/bin/asc`. To use this CLI from a general terminal, a wrapper in a
PATH directory can execute `"$HOME/.blitz/bin/asc" "$@"`. A separate official
ASC executable and additional `asc-upstream`/`asc-blitz` aliases are unnecessary.

The Blitz wrapper reuses its existing API-key profile via `ASC_CONFIG_PATH` and
`ASC_BYPASS_KEYCHAIN`. Validate with `asc auth status --validate`; do not copy
credentials or start a new login as a routine migration. Check `command -v asc`
and `asc version` when investigating PATH conflicts. Updating ASC does not itself
extend Apple web-session lifetime; the persistent WebKit fix is separate.

## Devices and MCP

Keep the existing `blitz_macos` and `blitz-iphone` Codex server names when moving their settings into `~/.codex/config.toml`; project settings can override global settings. Do not launch duplicate servers under new aliases. The iPhone server is a separate npm project and can also be used without the Blitz GUI.
