# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

Node/npm versions and official archive checksums are defined centrally in
`config/node-toolchain.json`. See `docs/node-toolchain.md`. The installed runtime
and release scripts must use that tested pair; do not substitute a moving
`current`/`latest` alias or apply the ASC documentation website's `.nvmrc` to Blitz.

```bash
# Debug build
swift build

# Release build
swift build -c release

# Fetch pinned helper dependency
git submodule update --init --recursive

# Bundle as macOS .app (signs with Developer ID)
bash scripts/bundle.sh release

# Full release: bump version, bundle app, build pkg, deploy
npm run release

# Run tests
swift test

# Run a single test
swift test --filter BlitzTests.SimctlClientTests/testParseDeviceList

# Build installer pkg
bash scripts/build-pkg.sh
```

## Architecture

**Blitz** is a native macOS SwiftUI app (requires macOS 14+) for iOS development. It provides simulator management, screen capture, App Store Connect integration, and a shared MCP/CLI backend for Codex, Claude Code and OpenCode integration. Built with Swift Package Manager (no Xcode project). Source bundling also depends on the pinned ASC helper submodule in `deps/App-Store-Connect-CLI-helper` and a local Go toolchain.

### Single-target structure

All Swift source lives in `src/`. Core types (process execution, simulator control, device interaction, project metadata) live alongside UI, services, and the MCP server in one executable target.

### App State

Single `AppState` (`@Observable`) object at `AppState.swift` holds all app state. Child observable managers:
- `ProjectManager` — project list and loading
- `SimulatorManager` — simulator lifecycle (boot/shutdown via `SimctlClient`)
- `SimulatorStreamManager` — screen capture via `ScreenCaptureKit` + Metal rendering
- `ASCManager` — App Store Connect API integration
- `ProjectSetupManager` — project scaffolding for different project types

### Navigation

`AppTab` enum defines all tabs, grouped into Build (simulator, tests, assets), Release (ASC tabs), Insights, TestFlight, and Settings. `ContentView` uses `NavigationSplitView` with `SidebarView` + `DetailView` that switches on `appState.activeTab`.

### MCP and release CLI

```
Agent ←stdio→ ~/.blitz/blitz-macos-mcp ←Unix socket→ MCPServerService (Swift actor)
```

- `MCPServerService` serves the local socket; a running listener does not prove an agent is connected.
- `MCPToolRegistry` defines the available tools. Agent configuration can restrict this list independently.
- `MCPToolExecutor` executes tool calls. Mutations retain Blitz's own approval and release checks.
- `~/.blitz/bin/blitz-neo release` uses the same helper and release journal. See `docs/release-workflow.md`.
- App and `asc` share the pinned bundled helper; the optional shell entry only adds command lookup paths.
- Settings inspect integrations without rewriting global client configuration. Codex tool allowlists and approvals are separate concepts.

### Device Interaction

Two paths depending on target device:
- **Simulator**: `SimctlClient` (xcrun simctl) for lifecycle + `IDBClient` for touch/swipe/describe (via `idb` CLI)
- **Physical device**: `WDAClient` (WebDriverAgent HTTP API on port 8100) for touch/swipe/screenshots

`DeviceInteractionService` is the unified actor that dispatches to either path.

### Screen Capture

`SimulatorCaptureService` uses `ScreenCaptureKit` (SCStream) to capture the Simulator.app window. Frames are rendered via `MetalRenderer` using a Metal pipeline. Stream pauses/resumes on tab switches to conserve resources.

### Project Storage

Projects are stored at `~/Library/Application Support/Blitz/projects/{projectId}/`. Each project has a `.blitz/project.json` metadata file (`BlitzProjectMetadata`). Supported project types: `blitz`, `react-native`, `swift`, `flutter`.

## Key Patterns

- All services that need isolation use Swift `actor` (e.g., `MCPServerService`, `DeviceInteractionService`)
- UI mutations go through `@MainActor` / `MainActor.run`
- External processes are managed via `ProcessRunner.run()` (async one-shot) or `ProcessRunner.stream()` (long-running with stdout/stderr callbacks, returns `ManagedProcess`)
- The app uses `@Observable` (Observation framework) rather than `ObservableObject`/`@Published`
- Linked system frameworks: ScreenCaptureKit, Metal, MetalKit, CoreMedia, AVFoundation, AppKit
