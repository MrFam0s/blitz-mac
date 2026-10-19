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
with its checksum. The weekly ASC update preparation is unchanged.

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

## Build and validation

Initialize the pinned submodule and install Go as specified by its `go.mod`:

```sh
git submodule update --init --recursive
swift test --build-system native
BLITZ_SWIFT_BUILD_SYSTEM=native \
CODESIGN_TIMESTAMP=none bash scripts/bundle.sh release
```

The `native` build engine avoids requiring the optional Metal toolchain with Xcode 27. It is deprecated by Swift and is a local compatibility fallback; with the Metal toolchain installed, use the default engine. `BLITZ_SWIFT_BUILD_SYSTEM` is optional and does not change the default build engine.

Without `APPLE_SIGNING_IDENTITY`, the bundle is ad-hoc signed, not notarized. Existing Keychain or macOS permissions may require approval for the rebuilt app. The default build compiles the pinned ASC source with the Blitz adapter. `BLITZ_ASCD_PATH` accepts a prebuilt helper only if its protocol and pinned version match. See `helpers/asc-overlay/README.md` for provenance and Go tests.

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
