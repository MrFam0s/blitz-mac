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
        guard let selectedDeviceID else { return nil }
        return simulators.first {
            $0.isBooted && $0.udid.caseInsensitiveCompare(selectedDeviceID) == .orderedSame && $0.supportsAppInteraction
        }?.udid
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

    @discardableResult
    func loadSimulators() async -> Bool {
        let token = revision
        do {
            let devices = try await service.listDevices()
            guard token == revision, !Task.isCancelled else { return false }
            simulators = devices.map {
                SimulatorInfo(udid: $0.udid, name: $0.name, state: $0.state,
                              deviceTypeIdentifier: $0.deviceTypeIdentifier, lastBootedAt: $0.lastBootedAt)
            }
            return true
        } catch {
            guard token == revision, !Task.isCancelled else { return false }
            errorMessage = L10n.tr("Simulatoren konnten nicht geladen werden. Prüfe, ob Xcode installiert ist, und versuche es erneut.")
            return false
        }
    }

    /// Tab navigation observes CoreSimulator. Only an explicit user action may boot a device.
    func runningDeviceForPreview(in project: Project?) async -> String? {
        activate(project: project)
        guard project?.platform == .iOS else { return nil }
        errorMessage = nil
        guard await loadSimulators(), projectID == project?.id else { return nil }
        return bootedDeviceId
    }

    /// An explicit choice is persisted before starting it. A failed boot can be retried.
    @discardableResult
    func selectDevice(_ udid: String, for project: Project?) async -> Bool {
        activate(project: project)
        guard let project, project.platform == .iOS else {
            errorMessage = L10n.tr("Wähle zuerst ein iOS-Projekt und anschließend einen Simulator.")
            return false
        }
        guard !isBooting else { return false }
        let token = revision
        isBooting = true
        defer { if token == revision { isBooting = false } }
        errorMessage = nil
        await loadSimulators()
        guard token == revision, !Task.isCancelled, errorMessage == nil else { return false }
        guard let device = simulators.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }),
              device.supportsAppInteraction else {
            errorMessage = L10n.tr("Dieser Simulator ist nicht verfügbar oder wird nicht unterstützt. Wähle ein anderes Gerät.")
            return false
        }
        do {
            try saveSelection(project, device.udid)
        } catch {
            errorMessage = L10n.tr("Der Simulator für dieses Projekt konnte nicht gespeichert werden: \(error.localizedDescription)")
            return false
        }
        savedSelections[project.id] = device.udid
        selectedDeviceID = device.udid
        isBooting = false
        return await startSelectedDevice(for: project)
    }

    @discardableResult
    func startSelectedDevice(for project: Project?) async -> Bool {
        activate(project: project)
        guard let project, project.platform == .iOS else {
            errorMessage = L10n.tr("Wähle ein iOS-Projekt, um einen Simulator zu verwenden.")
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
        guard let device = simulators.first(where: { $0.udid.caseInsensitiveCompare(selectedDeviceID) == .orderedSame }),
              device.supportsAppInteraction else {
            errorMessage = L10n.tr("Der gespeicherte Simulator ist nicht verfügbar. Wähle ein anderes Gerät für dieses Projekt.")
            return false
        }
        bootingDeviceName = device.name
        do {
            if !device.isBooted { try await service.bootInBackground(udid: device.udid) }
            guard token == revision, !Task.isCancelled else { return false }
            await loadSimulators()
            guard token == revision, !Task.isCancelled else { return false }
            guard bootedDeviceId == device.udid else {
                errorMessage = L10n.tr("Der Simulator konnte nicht vollständig gestartet werden. Versuche es erneut.")
                return false
            }
            return true
        } catch {
            guard token == revision, !Task.isCancelled else { return false }
            errorMessage = L10n.tr("\(device.name) konnte nicht gestartet werden: \(error.localizedDescription)")
            return false
        }
    }
}

enum SimulatorSelectionError: LocalizedError {
    case projectUnavailable
    var errorDescription: String? { L10n.tr("Der Projektordner konnte nicht gelesen werden.") }
}
