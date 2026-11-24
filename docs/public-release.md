# Public release preparation

Public downloads come from this fork's GitHub releases. The current release is
**1.0.85, build 105**, with ASC 7.2.0. Build 100 uses the tag `1.0.80`; the
earlier dashboard distribution remains available as `v1.0.80` (build 99).
Version 1.0.75 was the first regular
release, following the 1.0.73 and 1.0.74 previews. Downloads
target Apple Silicon. `npm run release` only prepares a
DMG from an already built signed app; it does not change a version, create a tag,
push to either remote or publish a release. Publication remains an explicit
maintainer action. Never run the old upstream release/deployment recipe from the
historical CI migration document for this fork.

## Build and verify

Use the versions in `config/node-toolchain.json`, the pinned ASC submodule and
the Go version required by its `go.mod`. Configure `GO`, `BLITZ_NODE_BIN` and your
own `APPLE_SIGNING_IDENTITY` as described in the README. Do not put credentials
in tracked files. The minimum supported macOS version is centralized in
`config/macos-deployment-target.txt`; every bundled native executable is checked
against it, including an externally supplied `BLITZ_ASCD_PATH`.

```bash
swift test --build-system native --jobs 4
bash scripts/test-asc-helper.sh
python3 -B scripts/test-release-metadata.py

BLITZ_REQUIRE_SIGNED_RELEASE=1 BLITZ_SWIFT_BUILD_SYSTEM=native \
  BLITZ_BUILD_JOBS=4 bash scripts/bundle.sh release
npm run release
```

The DMG builder verifies identity, version/build, architectures, Developer ID
signatures, hardened runtime, secure timestamps and deployment targets. It copies
only the built app plus an Applications link and a short installation note.
It refuses to overwrite an existing artifact. License notices are embedded by
the bundle builder from the actual Swift/Go dependencies.

The legacy PKG is not the public download format: its installation scripts have
broader Xcode/runtime setup behavior than a drag-and-drop download should have.
Do not execute its embedded postinstall as a manual step for this download.
Simulator creation and per-project selection inside the app remain available.
The native ASC and macOS MCP/CLI are provisioned at launch. Optional iPhone
MCP/idb setup remains separate on a new Mac.

## Notarize, staple and inspect

Use the already configured ASC account with notarization permission, or your own
Apple `notarytool` profile. Never extract an account's keys into release notes or
the repository. Submit through the shared ASC CLI and attach/verify the ticket
with Apple's local tool:

```bash
dmg="build/public/1.0.85-build105/BlitzNeo-1.0.85-arm64.dmg"
asc notarization submit --file "$dmg" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 \
  "$dmg"
```

Require Apple's status to be **Accepted** before announcing a notarized release.
ASC 6.6.1's staple wrapper reported an artifact-change verification error after
Apple successfully attached this DMG's ticket. Do not blindly repeat that
mutation: inspect the existing ticket with `xcrun stapler validate` and Gatekeeper.
Both independent checks passed for build 82. The native commands above avoid
relying on that wrapper's post-staple result.
Mount the final DMG read-only, verify the contained app's deep/strict signature
and its version/build, then detach it. Check first-launch behavior without
overwriting an active user's helpers or credentials. Distinguish host checks
from tests on a clean Mac or the oldest supported OS; do not claim the latter
without actually running them.

Generate `SHA256SUMS` **after** stapling, from the final DMG. Record exact Swift,
ASC, packaging and signing results plus known limits in release notes. Do not
include local verification logs, private state, credentials or project data.

## Publish

Pushing to `main` does not publish a release. Once publication is approved,
verify the tested commit is on this fork’s `main`, create a release draft
targeting that exact commit, and upload only the final DMG and `SHA256SUMS`.
Review the draft, then publish an authorized regular release with **prerelease
disabled** and mark it as the latest release. Use prerelease only when a preview
is explicitly intended.
Do not use the upstream remote or a moving branch as an implicit release target.
Verify the public tag, asset sizes and digests after publication.

GitHub source hosting and release downloads are the distribution mechanism; no
paid Actions or external deployment service is required. Regular releases appear
at GitHub's `releases/latest` endpoint. The current in-app updater only installs
legacy ZIP/PKG packages and does not install DMGs. Keep the download DMG-only and
document manual replacement in Applications; do not add a legacy installer merely
to enable that updater. Preview releases remain outside the stable endpoint.
