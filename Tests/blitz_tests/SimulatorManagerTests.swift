import Foundation
import ScreenCaptureKit
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
    await L10n.$overrideLanguage.withValue("de") {
        let driver = SimulatorTestDriver(devices: [simDevice("other", booted: true)])
        let manager = SimulatorManager(service: driver, saveSelection: { _, _ in })
        #expect(await manager.startSelectedDevice(for: simProject("new")) == false)
        #expect(manager.selectedDeviceID == nil)
        #expect(await manager.startSelectedDevice(for: simProject("missing", selected: "deleted")) == false)
        #expect(manager.selectedDeviceID == "deleted")
        #expect(manager.errorMessage?.contains("nicht verfügbar") == true)
        #expect(await driver.bootCalls.isEmpty)
    }
}

@MainActor
@Test func simulatorDoesNotBootWhenProjectPreferenceCannotBeSaved() async {
    await L10n.$overrideLanguage.withValue("en") {
        let driver = SimulatorTestDriver(devices: [simDevice("mine")])
        let manager = SimulatorManager(service: driver, saveSelection: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(await manager.selectDevice("mine", for: simProject("one")) == false)
        #expect(manager.selectedDeviceID == nil)
        #expect(manager.errorMessage?.contains("save") == true)
        #expect(await driver.bootCalls.isEmpty)
    }
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

@MainActor
@Test func simulatorAcceptsRenamedDuoAndNewIPadsAndRejectsOtherFamilies() async {
    let project = simProject("ios")
    func device(_ id: String, type: String) -> SimctlClient.SimctlDevice {
        .init(udid: id, name: "iPhone 17 misleading project name", state: "Booted", isAvailable: true,
              deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType." + type, lastBootedAt: nil)
    }
    let service = SimulatorTestDriver(devices: [
        device("duo", type: "iPhone-Duo"), device("ipad", type: "iPad-Pro-future"),
        device("watch", type: "Apple-Watch-Series-12"), device("tv", type: "Apple-TV-4K")
    ])
    var selections: [String] = []
    let manager = SimulatorManager(service: service, saveSelection: { _, id in selections.append(id) })
    #expect(await manager.selectDevice("duo", for: project))
    #expect(await manager.selectDevice("ipad", for: project))
    #expect(await manager.selectDevice("watch", for: project) == false)
    #expect(await manager.selectDevice("tv", for: project) == false)
    #expect(selections == ["duo", "ipad"])
    #expect(await service.bootCalls.isEmpty)
}

@Test func deviceHubUsesTheActiveScreenAndItsCurrentOrientationForTouches() {
    let outer = CGSize(width: 466, height: 678)
    let inner = CGSize(width: 669, height: 951)
    let crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    let closed = DeviceHubScreenGeometry.Viewport(crop: crop, windowSize: outer)
    let open = DeviceHubScreenGeometry.Viewport(crop: crop, windowSize: CGSize(width: 951, height: 669))
    #expect(closed.orientedPoints(for: outer) == outer)
    #expect(open.orientedPoints(for: inner) == CGSize(width: 951, height: 669))
    #expect(closed.orientedPoints(for: inner) == nil)
    #expect(open.orientedPoints(for: outer) == nil)
    #expect(open.orientedPoints(for: .zero) == nil)
    #expect(SimulatorConfigDatabase.legacyConfig(for: "iPhone 17") != nil)
    #expect(SimulatorConfigDatabase.legacyConfig(for: "iPhone Duo") == nil)
    let legacy = SimulatorInfo(udid: "old", name: "Project iPhone 16 Pro", state: "Shutdown",
                               deviceTypeIdentifier: nil, lastBootedAt: nil)
    #expect(legacy.supportsAppInteraction)
    #expect(legacy.legacyConfig?.widthPoints == 402)
}

@Test func simulatorCaptureSelectsOnlyTheRequestedUnambiguousWindow() {
    let titles = ["Other App iPhone 17 — iOS 27", "My App iPhone 17 — iOS 27", "iPhone 17 Pro — iOS 27"]
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: titles, deviceName: "My App iPhone 17") == 1)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: titles, deviceName: "iPhone 17") == nil)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: ["iPhone 17", "iPhone 17"], deviceName: "iPhone 17") == nil)
    #expect(SimulatorCaptureService.matchingWindowIndex(titles: ["iPhone 17 (27.0)"], deviceName: "iPhone 17") == 0)
}

@Test func simulatorPreviewRejectsAWindowReusedForAnotherProject() {
    let target = SimulatorCaptureService.WindowTarget(id: 12, processID: 34, deviceName: "My Project iPhone")
    #expect(target.matches(id: 12, processID: 34, title: "My Project iPhone — iOS 27"))
    #expect(!target.matches(id: 12, processID: 34, title: "Other Project iPhone — iOS 27"))
    #expect(!target.matches(id: 12, processID: 34, title: nil))
    #expect(!target.matches(id: 12, processID: nil, title: "My Project iPhone"))
    #expect(!target.matches(id: 12, processID: 35, title: "My Project iPhone"))
    #expect(!target.matches(id: 13, processID: 34, title: "My Project iPhone"))
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
    #expect(try newViewer.openArguments(udid: id, inBackground: false) == ["-a", hub, arguments[3]])
    #expect(url.scheme == "devices")
    #expect(url.path == "/device/open")
    #expect(url.queryItems == [URLQueryItem(name: "id", value: id)])
    let bothViewers = { (path: String) in path == legacy || path == hub }
    #expect(try SimulatorApplication.resolve(developerDirectory: developer, exists: bothViewers).kind == .deviceHub)
    #expect(try SimulatorApplication.resolve(developerDirectory: developer, preferred: .simulator,
                                             exists: bothViewers).url.path == legacy)
    #expect(try SimulatorApplication.resolve(developerDirectory: developer, preferred: .simulator,
                                             exists: { $0 == hub }).kind == .deviceHub)
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

@MainActor
@Test func simulatorPreviewChoosesAUsableCaptureBackendWithoutPrompting() {
    func native(_ viewer: SimulatorApplication.Kind?, recording: Bool = true, accessibility: Bool = true,
                screens: Int = 1, type: String = "com.apple.CoreSimulator.SimDeviceType.iPhone-17") -> Bool {
        SimulatorStreamManager.prefersNativePreview(
            deviceType: type, integratedScreenCount: screens, viewer: viewer,
            screenRecordingAllowed: recording, accessibilityAllowed: accessibility
        )
    }
    #expect(!native(.deviceHub))
    #expect(native(.deviceHub, accessibility: false))
    #expect(native(.deviceHub, recording: false))
    #expect(!native(.simulator, accessibility: false))
    #expect(native(.simulator, recording: false))
    #expect(native(nil))
    #expect(native(.deviceHub, screens: 2))
    #expect(!native(.deviceHub, accessibility: false, screens: 0))
    #expect(native(.deviceHub, screens: 0, type: SimulatorPose.deviceType))
}

@MainActor
@Test func simulatorPreviewDetectsTestShutdownOnlyForItsOwnDevice() {
    let selected = simDevice("mine", booted: true)
    let parallel = SimctlClient.SimctlDevice(udid: "parallel", name: selected.name, state: "Booted",
        isAvailable: true, deviceTypeIdentifier: selected.deviceTypeIdentifier, lastBootedAt: nil)
    #expect(!SimulatorStreamManager.deviceHasStopped(udid: selected.udid, in: [parallel, selected]))
    #expect(SimulatorStreamManager.deviceHasStopped(udid: selected.udid, in: [parallel, simDevice("mine")]))
    #expect(SimulatorStreamManager.deviceHasStopped(udid: selected.udid, in: [parallel]))
    #expect(SimulatorStreamManager.deviceHasStopped(udid: selected.udid, in: []))
    #expect(!SimulatorStreamManager.deviceHasStopped(udid: selected.udid, in: nil))
}

@MainActor
@Test func simulatorPreviewAfterShutdownExposesRestartWithoutRequestingPermissions() async {
    let stopped = simDevice("mine")
    let parallel = SimctlClient.SimctlDevice(udid: "parallel", name: stopped.name, state: "Booted",
        isAvailable: true, deviceTypeIdentifier: stopped.deviceTypeIdentifier, lastBootedAt: nil)
    let stream = SimulatorStreamManager(listDevices: { [parallel, stopped] in [parallel, stopped] })
    await stream.startStreaming(bootedDeviceId: stopped.udid)
    #expect(stream.stoppedDeviceID == stopped.udid)
    #expect(stream.closedWindowDeviceID == nil)
    #expect(!stream.isCapturing)
    #expect(stream.interaction == nil)
    #expect(stream.errorMessage == nil)
    #expect(!stream.needsAccessibilityPermission)
    #expect(!stream.needsScreenRecordingPermission)

    await stream.stopStreaming()
    #expect(stream.stoppedDeviceID == nil)
}

@Test func simulatorCaptureIdentifiesARealScreenRecordingDenialByDomainAndCode() {
    let domain = SCStreamError.errorDomain
    let denied = SCStreamError.Code.userDeclined.rawValue
    let classification = SimulatorCaptureService.CaptureError.classify
    let screenDenied = classification(NSError(domain: domain, code: denied))
    #expect(screenDenied.requiresScreenRecordingPermission)
    #expect(!screenDenied.requiresAccessibilityPermission)
    let accessibilityDenied = classification(SimulatorCaptureService.CaptureError.accessibilityDenied)
    #expect(accessibilityDenied.requiresAccessibilityPermission)
    #expect(!accessibilityDenied.requiresScreenRecordingPermission)
    let missingWindows = classification(NSError(domain: domain, code: SCStreamError.Code.noWindowList.rawValue))
    #expect(!missingWindows.requiresScreenRecordingPermission)
    #expect(!missingWindows.requiresAccessibilityPermission)
    let stopped = classification(NSError(domain: domain, code: SCStreamError.Code.userStopped.rawValue))
    guard case .simulatorWindowClosed = stopped else {
        Issue.record("Stopping the stream should be reported as a closed preview")
        return
    }
    #expect(!classification(NSError(domain: NSCocoaErrorDomain, code: denied)).requiresScreenRecordingPermission)
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
