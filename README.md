# Blitz Neo

<img src="src/resources/blitz-icon.png" width="128" alt="Blitz Neo app icon" />

Blitz Neo is an independently maintained macOS developer workspace by AmoSystems,
based on [Blitz](https://github.com/blitzdotdev/blitz-mac). It combines App Store
Connect management, an integrated coding terminal, MCP tools and simulator
controls. This is a personal maintenance fork, not an official Blitz successor.

**In development. No public Blitz Neo download or Mac App Store release is
currently offered.** The source repository is public; this does not mean a
reviewed distribution build is available.

## Features

- App overview, version drafts, listing text, screenshots, pricing and review data.
- TestFlight builds, groups, beta information and feedback.
- Cached views and layouts that adapt beside the integrated terminal.
- Project-specific simulator selection and device tooling.
- Coding assistants through the terminal and compatible MCP tools.
- Separate draft creation and an explicitly started publication workflow.
- One pinned ASC implementation shared by the app and its CLI wrapper.

## Identity and existing installations

The app is **Blitz Neo**, with bundle ID `org.amosystems.BlitzNeo`, installed as
`/Applications/Blitz Neo.app`. The internal Swift executable is still `Blitz`.

Existing `~/.blitz` projects, settings, CLI wrappers, Keychain service names and
MCP server names (`blitz_macos`, `blitz-iphone`) remain stable for compatibility.
Selected UI preferences and window layout migrate once from `com.blitz.macos`;
existing Neo preferences take precedence. Existing cache directories are retained.

macOS sees the new bundle identifier as a new app. Screen Recording,
Accessibility and Keychain access may require renewed user consent, and Apple's
web login may need to be completed again. Permissions are not bypassed or reset.
The package installer backs up the recognized native predecessor after installing
the replacement; it does not remove projects or user data.

## Build and test

See [MAINTENANCE.md](MAINTENANCE.md) for the exact pinned toolchain, helper
provenance, validation history and platform-specific limitations.

```bash
git clone --branch maintenance/auth-and-tooling https://github.com/MrFam0s/blitz-mac.git
cd blitz-mac
git submodule update --init --recursive

# Local compatibility workflow for this Mac / Xcode 27.
swift test --build-system native --jobs 4
BLITZ_SWIFT_BUILD_SYSTEM=native BLITZ_BUILD_JOBS=4 bash scripts/bundle.sh release
open ".build/Blitz Neo.app"
```

The native build engine is a local compatibility fallback. A normal SwiftPM
build may be used with the appropriate Xcode toolchain components installed.
The bundle is ad-hoc signed unless `APPLE_SIGNING_IDENTITY` selects your own
Developer ID identity. Signing does not notarize or publish the app.

The ASC helper is built from the pinned official source with the protocol adapter
in [helpers/asc-overlay](helpers/asc-overlay/README.md). Do not substitute an
ordinary standalone ASC binary. The app and terminal share the same helper.

GitHub Actions remain paused/manual for this fork. Local checks are the active
validation route. Do not enable paid GitHub features or raise spending limits.

## Data and privacy

Projects and settings remain local under `~/.blitz`; Store data is requested from
Apple for the selected account. The app includes credentials and session handling,
so local state and verification logs must not be committed. Coding assistants
use their own account, network and permission settings.

Maintenance builds do not embed analytics configuration. The old community App
Wall has been removed. Existing MCP transport names and local paths remain
unchanged to keep configured clients working.

## Attribution and license

Blitz Neo modifies Blitz by Minjune Song and Palash Bansal. The original copyright
and attribution notices are retained in [LICENSE](LICENSE) and [NOTICE](NOTICE).
Blitz is licensed under Apache 2.0. Third-party helpers retain their own licenses;
see their respective source and overlay documentation.

The new icon is an original generated concept adapted for this fork. Its production
asset and generation details are documented in [branding/README.md](branding/README.md).
Use of a new name does not imply endorsement by the original authors or Apple.
