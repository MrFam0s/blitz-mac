import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func simulatorProjectActivationAndInventoryDoNotBootOrAdoptOtherDevices() async {
    let driver = SimulatorTestDriver(devices: [simDevice("other", booted: true), simDevice("mine")])
    let manager = SimulatorManager(service: driver, saveSelection: { _, _ in })
    manager.activate(project: simProject("one", selected: "mine"))
    await manager.loadSimulators()
    #expect(manager.selectedDeviceID == "mine")
    #expect(manager.bootedDeviceId == nil)
    #expect(await driver.bootCalls.isEmpty)
}

@MainActor
@Test func simulatorSelectionIsSavedPerProjectAndKeepsOtherDevicesRunning() async {
    let driver = SimulatorTestDriver(devices: [simDevice("other", booted: true), simDevice("mine")])
    var saved: [String: String] = [:]
    let manager = SimulatorManager(service: driver, saveSelection: { saved[$0.id] = $1 })
    #expect(await manager.selectDevice("mine", for: simProject("one")))
    #expect(saved == ["one": "mine"])
    #expect(manager.bootedDeviceId == "mine")
    manager.activate(project: simProject("two", selected: "other"))
    #expect(await manager.startSelectedDevice(for: simProject("two", selected: "other")))
    manager.activate(project: simProject("one"))
    #expect(manager.selectedDeviceID == "mine")
    #expect(await driver.bootCalls == ["mine"])
    #expect(await driver.devices.filter(\.isBooted).count == 2)
}

@MainActor
@Test func simulatorMissingSelectionDoesNotBootAnArbitraryDevice() async {
    let driver = SimulatorTestDriver(devices: [simDevice("other", booted: true)])
    let manager = SimulatorManager(service: driver, saveSelection: { _, _ in })
    #expect(await manager.startSelectedDevice(for: simProject("new")) == false)
    #expect(manager.selectedDeviceID == nil)
    #expect(await manager.startSelectedDevice(for: simProject("missing", selected: "deleted")) == false)
    #expect(manager.selectedDeviceID == "deleted")
    #expect(manager.errorMessage?.contains("unavailable") == true)
    #expect(await driver.bootCalls.isEmpty)
}

@MainActor
@Test func simulatorDoesNotBootWhenProjectPreferenceCannotBeSaved() async {
    let driver = SimulatorTestDriver(devices: [simDevice("mine")])
    let manager = SimulatorManager(service: driver, saveSelection: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(await manager.selectDevice("mine", for: simProject("one")) == false)
    #expect(manager.selectedDeviceID == nil)
    #expect(manager.errorMessage?.contains("save") == true)
    #expect(await driver.bootCalls.isEmpty)
}

@MainActor
@Test func simulatorIgnoresLateBootCompletionAfterProjectSwitch() async {
    let driver = SimulatorTestDriver(devices: [simDevice("mine"), simDevice("other", booted: true)], delayBoot: true)
    let manager = SimulatorManager(service: driver, saveSelection: { _, _ in })
    let task = Task { await manager.startSelectedDevice(for: simProject("one", selected: "mine")) }
    await driver.waitForBoot()
    manager.activate(project: simProject("two", selected: "other"))
    await driver.finishBoot()
    #expect(await task.value == false)
    #expect(manager.projectID == "two")
    #expect(manager.selectedDeviceID == "other")
    #expect(!manager.isBooting)
    #expect(manager.errorMessage == nil)
}

@MainActor
@Test func simulatorDoesNotStartForMacProjectsOrDuplicateRequests() async {
    let driver = SimulatorTestDriver(devices: [simDevice("mine")], delayBoot: true)
    let manager = SimulatorManager(service: driver, saveSelection: { _, _ in })
    let mac = Project(id: "mac", metadata: BlitzProjectMetadata(name: "Mac", type: .swift, platform: .macOS), path: "/tmp/mac")
    #expect(await manager.startSelectedDevice(for: mac) == false)
    let project = simProject("ios", selected: "mine")
    let task = Task { await manager.startSelectedDevice(for: project) }
    await driver.waitForBoot()
    #expect(await manager.startSelectedDevice(for: project) == false)
    await driver.finishBoot()
    #expect(await task.value)
    #expect(await driver.bootCalls == ["mine"])
}

@Test func simulatorCaptureSelectsOnlyTheRequestedUnambiguousWindow() {
    let titles = ["Other App iPhone 17 — iOS 27", "My App iPhone 17 — iOS 27", "iPhone 17 Pro — iOS 27"]
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: titles, deviceName: "My App iPhone 17") == 1)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: titles, deviceName: "iPhone 17") == nil)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: ["iPhone 17", "iPhone 17"], deviceName: "iPhone 17") == nil)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: ["iPhone 17 (27.0)"], deviceName: "iPhone 17") == 0)
}

@Test func simulatorViewerUsesSelectedXcodeForLegacyAndDeviceHub() throws {
    let developer = "/Applications/Xcode Preview.app/Contents/Developer"
    let legacy = developer + "/Applications/Simulator.app"
    let hub = "/Applications/Xcode Preview.app/Contents/Applications/DeviceHub.app"
    let id = "A2956D56-B83A-4B61-B52A-6DBC943D242D"
    let oldViewer = try SimulatorApplication.resolve(developerDirectory: developer + "\n", exists: { $0 == legacy })
    #expect(try oldViewer.openArguments(udid: id) == ["-g", "-a", legacy, "--args", "-CurrentDeviceUDID", id])
    let newViewer = try SimulatorApplication.resolve(developerDirectory: "/Applications/Xcode Preview.app", exists: { $0 == hub })
    #expect(newViewer.kind == .deviceHub)
    let arguments = try newViewer.openArguments(udid: id)
    #expect(Array(arguments.prefix(3)) == ["-g", "-a", hub])
    let url = try #require(URLComponents(string: arguments[3]))
    #expect(url.scheme == "devices")
    #expect(url.path == "/device/open")
    #expect(url.queryItems == [URLQueryItem(name: "id", value: id)])
    #expect(throws: SimulatorApplication.LaunchError.self) {
        try newViewer.openArguments(udid: "not-a-device&other=value")
    }
    #expect(throws: SimulatorApplication.LaunchError.self) {
        try SimulatorApplication.resolve(developerDirectory: "/Library/Developer/CommandLineTools", exists: { _ in false })
    }
}

@Test func simulatorLaunchAndWindowErrorsDoNotRequestPrivacyChanges() {
    #expect(!SimulatorCaptureService.CaptureError.simulatorWindowNotFound.requiresScreenRecordingPermission)
    #expect(!SimulatorCaptureService.CaptureError.ambiguousSimulatorName.requiresScreenRecordingPermission)
    #expect(!SimulatorCaptureService.CaptureError.captureStartFailed("connection closed").requiresScreenRecordingPermission)
    #expect(SimulatorCaptureService.CaptureError.screenRecordingDenied("denied").requiresScreenRecordingPermission)
    #expect(!SimulatorCaptureService.CaptureError.accessibilityDenied.requiresScreenRecordingPermission)
    #expect(!SimulatorCaptureService.CaptureError.deviceScreenNotFound.requiresScreenRecordingPermission)
}

@Test func deviceHubScreenBoundsExcludeAsymmetricChromeAndMapTouches() throws {
    let window = CGRect(x: 120, y: 80, width: 790, height: 1720)
    let screen = CGRect(x: 180, y: 214, width: 670, height: 1454)
    let crop = try #require(DeviceHubScreenGeometry.normalizedRect(content: screen, window: window))
    #expect(abs(crop.minX * window.width - 60) < 0.001)
    #expect(abs(crop.minY * window.height - 134) < 0.001)
    #expect(abs(crop.height * window.height - 1454) < 0.001)
    #expect(DeviceHubScreenGeometry.normalizedRect(content: screen.offsetBy(dx: 1000, dy: 0), window: window) == nil)
    #expect(DeviceHubScreenGeometry.normalizedRect(content: .zero, window: window) == nil)
    let config = SimulatorDeviceConfig(toolbarHeight: 0, toolbarOffset: 0,
        widthPoints: 402, heightPoints: 874, borderX: 0, borderY: 0)
    let point = SimulatorConfigDatabase.viewToSimulatorCoords(viewX: 167.5, viewY: 1090.5,
        viewWidth: 670, viewHeight: 1454, config: config, frameWidth: 790, frameHeight: 1720)
    #expect(abs(point.x - 100.5) < 0.001)
    #expect(abs(point.y - 655.5) < 0.001)
    let reverse = SimulatorConfigDatabase.simulatorToViewCoords(simX: point.x, simY: point.y,
        viewWidth: 670, viewHeight: 1454, config: config, frameWidth: 790, frameHeight: 1720)
    #expect(abs(reverse.x - 167.5) < 0.001)
    #expect(abs(reverse.y - 1090.5) < 0.001)
}

@Test func deviceHubFindsScreenContainerWithoutAssumingItsAccessibilityRole() {
    struct Node {
        var id: String? = nil
        var frame: CGRect? = nil
        var children: [Node] = []
    }
    let bounds = CGRect(x: 60, y: 134, width: 670, height: 1454)
    let screen = Node(frame: bounds, children: [Node(id: "app-content")])
    let controls = [Node(id: "camera.viewfinder"), Node(id: "record.circle")]
    let root = Node(children: [Node(children: [Node(id: "header"), screen] + controls)])
    let find = { (node: Node) in
        DeviceHubScreenGeometry.screenBounds(in: node, children: { $0.children },
            identifier: { $0.id }, frame: { $0.frame })
    }
    #expect(find(root) == [bounds])
    #expect(find(Node(children: [screen])) == [])
    // Device Hub exposes host and remote AX containers for the same screen.
    #expect(find(Node(children: [screen, screen] + controls)) == [bounds])
    let rounded = Node(frame: bounds.offsetBy(dx: 0.1, dy: 0), children: [Node(id: "remote-content")])
    #expect(find(Node(children: [screen, rounded] + controls)) == [bounds])
    // Genuinely different screen bounds must still be rejected as ambiguous.
    let other = Node(frame: bounds.offsetBy(dx: 200, dy: 0), children: [Node(id: "other")])
    #expect(find(Node(children: [screen, other] + controls)).count == 2)
    #expect(DeviceHubScreenGeometry.matchesWindow(bounds, bounds.offsetBy(dx: 0.5, dy: 0)))
    #expect(!DeviceHubScreenGeometry.matchesWindow(bounds, bounds.offsetBy(dx: 100, dy: 0)))
}

@Test func deviceHubWaitsForRemoteLayoutButNotPermissionFailures() async throws {
    let bounds = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    var attempts = 0
    let result = try await DeviceHubScreenGeometry.waitForScreen(maxAttempts: 3, retryDelay: .zero) {
        attempts += 1
        if attempts < 3 { throw SimulatorCaptureService.CaptureError.deviceScreenNotFound }
        return bounds
    }
    #expect(result == bounds)
    #expect(attempts == 3)
    attempts = 0
    do {
        _ = try await DeviceHubScreenGeometry.waitForScreen(maxAttempts: 3, retryDelay: .zero) {
            attempts += 1
            throw SimulatorCaptureService.CaptureError.accessibilityDenied
        }
        Issue.record("Permission denial must propagate")
    } catch SimulatorCaptureService.CaptureError.accessibilityDenied {}
    #expect(attempts == 1)
    attempts = 0
    do {
        _ = try await DeviceHubScreenGeometry.waitForScreen(maxAttempts: 3, retryDelay: .zero) {
            attempts += 1
            throw SimulatorCaptureService.CaptureError.deviceScreenNotFound
        }
        Issue.record("Persistent ambiguity must propagate")
    } catch SimulatorCaptureService.CaptureError.deviceScreenNotFound {}
    #expect(attempts == 3)
}

private func simProject(_ id: String, selected: String? = nil) -> Project {
    Project(id: id, metadata: BlitzProjectMetadata(name: id, type: .swift, simulatorUDID: selected), path: "/tmp/\(id)")
}

private func simDevice(_ id: String, booted: Bool = false) -> SimctlClient.SimctlDevice {
    .init(udid: id, name: "\(id) Custom Project", state: booted ? "Booted" : "Shutdown", isAvailable: true,
          deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", lastBootedAt: nil)
}

private actor SimulatorTestDriver: SimulatorDeviceService {
    var devices: [SimctlClient.SimctlDevice]
    var bootCalls: [String] = []
    let delayBoot: Bool
    private var bootWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    init(devices: [SimctlClient.SimctlDevice], delayBoot: Bool = false) { self.devices = devices; self.delayBoot = delayBoot }
    func listDevices() async throws -> [SimctlClient.SimctlDevice] { devices }
    func bootInBackground(udid: String) async throws {
        bootCalls.append(udid)
        bootWaiter?.resume(); bootWaiter = nil
        if delayBoot { await withCheckedContinuation { finishWaiter = $0 } }
        devices = devices.map { $0.udid == udid ? simDevice(udid, booted: true) : $0 }
    }
    func waitForBoot() async {
        if bootCalls.isEmpty { await withCheckedContinuation { bootWaiter = $0 } }
    }
    func finishBoot() { finishWaiter?.resume(); finishWaiter = nil }
}
