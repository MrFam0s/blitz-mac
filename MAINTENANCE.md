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
