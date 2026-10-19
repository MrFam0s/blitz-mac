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
