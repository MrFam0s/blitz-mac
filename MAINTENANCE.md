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

## Build and validation

With the existing compatible Blitz helper installed:

```sh
swift test --build-system native
BLITZ_ASCD_PATH="$HOME/.blitz/bin/ascd" \
BLITZ_SWIFT_BUILD_SYSTEM=native \
CODESIGN_TIMESTAMP=none bash scripts/bundle.sh release
```

The `native` build engine avoids requiring the optional Metal toolchain with Xcode 27. It is deprecated by Swift and is a local compatibility fallback; with the Metal toolchain installed, use the default engine. `BLITZ_SWIFT_BUILD_SYSTEM` is optional and does not change the default build engine.

Without `APPLE_SIGNING_IDENTITY`, the bundle is ad-hoc signed, not notarized. Existing Keychain or macOS permissions may require approval for the rebuilt app. A local build can reuse the protocol-compatible helper from the installed app. To build the helper from source instead, initialize the pinned submodule and install its required Go version. Never substitute a regular `asc` binary for `ascd`.

## Independent ASC CLI

The official [App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI) can coexist with Blitz. Its public CLI and Blitz's long-lived `ascd` JSON-lines service are separate interfaces. Upgrading the standalone CLI does not upgrade Blitz's internal service or fix WebKit sign-in persistence.

For an existing Blitz API-key profile, the standalone CLI can be invoked with `ASC_CONFIG_PATH="$HOME/.blitz/asc-agent/config.json"` and `ASC_BYPASS_KEYCHAIN=1`. Validate via `asc auth status --validate`; do not copy credentials or run a new login as a routine migration step. Blitz-launched terminals may put `~/.blitz/bin` first in PATH, so inspect `command -v asc` and `asc version`, or use the explicit `asc-upstream` wrapper where installed.

## Devices and MCP

Keep the existing `blitz_macos` and `blitz-iphone` Codex server names when moving their settings into `~/.codex/config.toml`; project settings can override global settings. Do not launch duplicate servers under new aliases. The iPhone server is a separate npm project and can also be used without the Blitz GUI.
