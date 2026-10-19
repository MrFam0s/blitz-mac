import Foundation

protocol SimulatorDeviceService: Sendable {
    func listDevices() async throws -> [SimctlClient.SimctlDevice]
    func bootInBackground(udid: String) async throws
}

@MainActor
@Observable
final class SimulatorManager {
    private(set) var simulators: [SimulatorInfo] = []
    private(set) var selectedDeviceID: String?
    private(set) var projectID: String?
    private(set) var isBooting = false
    private(set) var bootingDeviceName: String?
    private(set) var errorMessage: String?
    private var revision = 0
    private var savedSelections: [String: String] = [:]
    private let service: any SimulatorDeviceService
    private let saveSelection: (Project, String) throws -> Void

    var bootedDeviceId: String? {
        simulators.first { $0.udid == selectedDeviceID && $0.isBooted }?.udid
    }

    init(
        service: any SimulatorDeviceService = SimulatorService(),
        saveSelection: @escaping (Project, String) throws -> Void = { project, udid in
            let storage = ProjectStorage()
            guard var metadata = storage.readMetadata(projectId: project.id) else {
                throw SimulatorSelectionError.projectUnavailable
            }
            metadata.simulatorUDID = udid
            try storage.writeMetadata(projectId: project.id, metadata: metadata)
        }
    ) {
        self.service = service
        self.saveSelection = saveSelection
    }

    /// Restore a project's choice without booting or adopting another running device.
    func activate(project: Project?) {
        guard projectID != project?.id else { return }
        revision += 1
        projectID = project?.id
        selectedDeviceID = project.flatMap { savedSelections[$0.id] ?? $0.metadata.simulatorUDID }
        isBooting = false
        bootingDeviceName = nil
        errorMessage = nil
    }

    func loadSimulators() async {
        let token = revision
        do {
            let devices = try await service.listDevices()
            guard token == revision, !Task.isCancelled else { return }
            simulators = devices.map {
                SimulatorInfo(udid: $0.udid, name: $0.name, state: $0.state,
                              deviceTypeIdentifier: $0.deviceTypeIdentifier, lastBootedAt: $0.lastBootedAt)
            }
        } catch {
            guard token == revision, !Task.isCancelled else { return }
            errorMessage = "Could not load simulators. Check that Xcode is installed and try again."
        }
    }

    /// An explicit choice is persisted before starting it. A failed boot can be retried.
    @discardableResult
    func selectDevice(_ udid: String, for project: Project?) async -> Bool {
        activate(project: project)
        guard let project, project.platform == .iOS else {
            errorMessage = "Select an iOS project before choosing a simulator."
            return false
        }
        guard !isBooting else { return false }
        let token = revision
        isBooting = true
        defer { if token == revision { isBooting = false } }
        errorMessage = nil
        await loadSimulators()
        guard token == revision, !Task.isCancelled, errorMessage == nil else { return false }
        guard let device = simulators.first(where: { $0.udid == udid }),
              SimulatorConfigDatabase.isSupported(device.displayName) else {
            errorMessage = "This simulator is unavailable or unsupported. Choose another device."
            return false
        }
        do {
            try saveSelection(project, udid)
        } catch {
            errorMessage = "Could not save this project's simulator: \(error.localizedDescription)"
            return false
        }
        savedSelections[project.id] = udid
        selectedDeviceID = udid
        isBooting = false
        return await startSelectedDevice(for: project)
    }

    @discardableResult
    func startSelectedDevice(for project: Project?) async -> Bool {
        activate(project: project)
        guard let project, project.platform == .iOS else {
            errorMessage = "Select an iOS project to use a simulator."
            return false
        }
        guard !isBooting else { return false }
        let token = revision
        isBooting = true
        errorMessage = nil
        defer {
            if token == revision { isBooting = false; bootingDeviceName = nil }
        }
        await loadSimulators()
        guard token == revision, !Task.isCancelled, errorMessage == nil else { return false }
        guard let selectedDeviceID else { return false }
        guard let device = simulators.first(where: { $0.udid == selectedDeviceID }),
              SimulatorConfigDatabase.isSupported(device.displayName) else {
            errorMessage = "The saved simulator is unavailable. Choose another device for this project."
            return false
        }
        bootingDeviceName = device.name
        do {
            if !device.isBooted { try await service.bootInBackground(udid: device.udid) }
            guard token == revision, !Task.isCancelled else { return false }
            await loadSimulators()
            guard token == revision, !Task.isCancelled else { return false }
            guard bootedDeviceId == device.udid else {
                errorMessage = "The simulator did not finish starting. Try again."
                return false
            }
            return true
        } catch {
            guard token == revision, !Task.isCancelled else { return false }
            errorMessage = "Could not start \(device.name): \(error.localizedDescription)"
            return false
        }
    }
}

enum SimulatorSelectionError: LocalizedError {
    case projectUnavailable
    var errorDescription: String? { "The project folder could not be read." }
}
