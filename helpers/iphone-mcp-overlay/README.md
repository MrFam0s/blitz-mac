# Maintained iPhone MCP

Official upstream: https://github.com/blitzdotdev/iPhone-mcp (MIT).
Pinned source: **0.1.18**, commit `3259f756279cd8cb6bc507b46369111fb5672fa2`,
held as `deps/iPhone-mcp`. The upstream license is included in every package.
The local package identifies itself as **0.1.18-blitz.1**.

`maintenance.patch` contains the source changes and regression tests. Build with
Node 22 and npm 10 using `bash scripts/build-iphone-mcp.sh`. This exports the exact
upstream commit, applies the patch, installs lockfile dependencies, runs tests and
packs the result. No npm publication is required. `npm-shrinkwrap.json` fixes
the install dependency tree. Package metadata records the upstream commit and
overlay SHA-256. The release bundle includes the tarball
and checksum; the installer uses `npm ci --omit=dev` in a staging directory
and builds the required native addon before replacing the installed
package and retains a backup. Never replace it with `@latest` during an update.

The overlay creates one private IDB companion socket per selected simulator,
without global discovery/cache or `idb kill`. CLI exit status acknowledges each
input; requests are serialized and bounded, and failed inputs are not replayed.
Text is sent directly as HID input using the selected simulator's active keyboard
preference. German QWERTZ (including umlauts) and US QWERTY are supported; unknown
layouts or unsupported characters fail before any part of the text is sent.
iOS autocorrection and smart punctuation still apply, so callers should verify
with `describe_after`. No pasteboard or paste permission is used; text travels on
stdin rather than process arguments. Subprocesses receive only OS/tool-path environment variables. EOF and shutdown
release owned helpers. Multiple booted simulators require an explicit UDID.

`scan_ui` and display dimensions use the same companion rather than the obsolete
native ax-scan linked to old IDB frameworks. Device names are not screen-size
identifiers. Xcode 27 simulated entries in devicectl are excluded from physical
phone discovery. Physical-device control remains on the existing WDA path and
must be verified separately on hardware.

The configured executable and MCP server name stay unchanged. Existing running
MCP processes retain their loaded code until their client reconnects; fresh
sessions report `0.1.18-blitz.1` during initialize.
