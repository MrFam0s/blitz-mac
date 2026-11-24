import Foundation
import SwiftUI

/// All navigation tabs in the app
enum AppTab: String, CaseIterable, Identifiable {
    // Top-level standalone tabs
    case dashboard
    case app

    // Release group (ASC)
    case appInformation  // Combined "App Information" tab (was Store Listing + App Details)
    case screenshots
    case monetization
    case review

    // Insights group
    case analytics
    case reviews

    // TestFlight group
    case builds
    case groups
    case betaInfo
    case feedback

    // Settings
    case settings

    var id: String { rawValue }

    var isASCTab: Bool {
        switch self {
        case .appInformation, .screenshots, .monetization, .review,
             .analytics, .reviews, .builds, .groups, .betaInfo, .feedback:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .app: "App"
        case .appInformation: L10n.tr("App-Informationen")
        case .screenshots: "Screenshots"
        case .monetization: L10n.tr("Monetarisierung")
        case .review: L10n.tr("App-Prüfung")
        case .analytics: L10n.tr("Statistiken")
        case .reviews: L10n.tr("Bewertungen")
        case .builds: "Builds"
        case .groups: L10n.tr("Testgruppen")
        case .betaInfo: L10n.tr("Beta-Informationen")
        case .feedback: L10n.tr("Rückmeldungen")
        case .settings: L10n.tr("Einstellungen")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .app: "app"
        case .appInformation: "info.circle"
        case .screenshots: "photo.on.rectangle"
        case .monetization: "dollarsign.circle"
        case .review: "star"
        case .analytics: "chart.line.uptrend.xyaxis"
        case .reviews: "bubble.left.and.bubble.right"
        case .builds: "hammer"
        case .groups: "person.3"
        case .betaInfo: "doc.text"
        case .feedback: "exclamationmark.bubble"
        case .settings: "gear"
        }
    }

    enum Group: String, CaseIterable {
        case release = "Release"
        case insights = "Insights"
        case testFlight = "TestFlight"

        var tabs: [AppTab] {
            switch self {
            case .release: [.appInformation, .screenshots, .monetization, .review]
            case .insights: [.analytics, .reviews]
            case .testFlight: [.builds, .groups, .betaInfo, .feedback]
            }
        }
    }
}

/// Sub-tabs within the App tab (top navbar)
enum AppSubTab: String, CaseIterable, Identifiable {
    case overview
    case simulator
    case tests
    case icon

    static let visibleCases: [AppSubTab] = allCases

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: L10n.tr("Übersicht")
        case .simulator: "Simulator"
        case .tests: "Tests"
        case .icon: "Icon"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.bar"
        case .simulator: "iphone"
        case .tests: "checkmark.circle"
        case .icon: "photo.badge.plus"
        }
    }
}

/// Root observable state for the entire app
@MainActor
@Observable
final class AppState {
    // Navigation
    var activeProjectId: String?
    var activeTab: AppTab = .dashboard
    var activeAppSubTab: AppSubTab = .overview
    var selectedOverlaySkin: TouchOverlaySkin = .laser

    // Child observable managers
    var projectManager = ProjectManager()
    var simulatorManager = SimulatorManager()
    var simulatorStream = SimulatorStreamManager()
    var gestureVisualization = GestureVisualizationSocketService()
    var settingsStore = SettingsService.shared
    var projectSetup = ProjectSetupManager()
    var ascManager = ASCManager()
    var autoUpdate = AutoUpdateManager()
    var terminalManager = TerminalManager()

    // Terminal panel visibility (toggle only — does not affect session lifecycle)
    var showTerminal = false
    var terminalPanelSize: CGFloat {
        get {
            CGFloat(settingsStore.terminalPosition == "right"
                ? settingsStore.terminalRightWidth : settingsStore.terminalBottomHeight)
        }
        set {
            guard newValue.isFinite, newValue > 0 else { return }
            if settingsStore.terminalPosition == "right" {
                settingsStore.terminalRightWidth = Double(newValue)
            } else {
                settingsStore.terminalBottomHeight = Double(newValue)
            }
        }
    }

    // Sheet control (toggled by menu bar, observed by ContentView)
    var showNewProjectSheet = false
    var showImportProjectSheet = false

// MCP approval flow
    var pendingApproval: ApprovalRequest?
    var showApprovalAlert: Bool = false
    var toolExecutor: MCPExecutor?
    var mcpServer: MCPServerService?

    init() {
        ascManager.appState = self
        // Boot MCP server eagerly — this runs before any SwiftUI view callback
        MCPBootstrap.shared.boot(appState: self)
        ascManager.loadStoredCredentialsIfNeeded()
    }

    var activeProject: Project? {
        guard let id = activeProjectId else { return nil }
        return projectManager.projects.first { $0.id == id }
    }

    private var simulatorActionTask: Task<Bool, Never>?
    private var simulatorActionRevision = 0
    private enum SimulatorAction: Equatable {
        case previewRunning, start, select(String)
    }

    func showRunningProjectSimulator() async {
        let projectID = activeProjectId
        let revision = simulatorActionRevision
        // An explicit start or selection already in progress takes precedence over navigation.
        _ = await simulatorActionTask?.value
        guard revision == simulatorActionRevision, activeProjectId == projectID,
              activeTab == .app, activeAppSubTab == .simulator, !Task.isCancelled else { return }
        await updateProjectSimulator(.previewRunning)
    }

    @discardableResult
    func startProjectSimulator(selecting udid: String? = nil) async -> Bool {
        await updateProjectSimulator(udid.map(SimulatorAction.select) ?? .start)
    }

    /// Serialize stream changes so a late capture cannot take over a new project.
    @discardableResult
    private func updateProjectSimulator(_ action: SimulatorAction) async -> Bool {
        let project = activeProject
        simulatorActionRevision += 1
        let token = simulatorActionRevision
        let previous = simulatorActionTask
        previous?.cancel()
        let task = Task { @MainActor in
            _ = await previous?.value
            guard token == simulatorActionRevision, activeProjectId == project?.id, !Task.isCancelled else { return false }
            simulatorManager.activate(project: project)
            let runningDevice = action == .previewRunning ? await simulatorManager.runningDeviceForPreview(in: project) : nil
            guard activeProjectId == project?.id, !Task.isCancelled else { return false }
            if let runningDevice, simulatorStream.isPreviewing(runningDevice) { return true }
            await simulatorStream.stopStreaming()
            guard activeProjectId == project?.id, !Task.isCancelled else { return false }
            let device: String?
            switch action {
            case .previewRunning:
                device = runningDevice
            case .start:
                guard await simulatorManager.startSelectedDevice(for: project) else { return false }
                device = simulatorManager.bootedDeviceId
            case .select(let udid):
                guard await simulatorManager.selectDevice(udid, for: project) else { return false }
                device = simulatorManager.bootedDeviceId
            }
            guard let device, activeProjectId == project?.id, !Task.isCancelled else { return false }
            if activeTab == .app && activeAppSubTab == .simulator {
                await simulatorStream.startStreaming(bootedDeviceId: device, openViewerIfNeeded: action != .previewRunning)
            }
            return !Task.isCancelled
        }
        simulatorActionTask = task
        defer { if simulatorActionRevision == token { simulatorActionTask = nil } }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stopProjectSimulator() async {
        simulatorActionRevision += 1
        let token = simulatorActionRevision
        let task = simulatorActionTask
        task?.cancel()
        _ = await task?.value
        guard token == simulatorActionRevision else { return }
        await simulatorStream.stopStreaming()
    }


}

// SettingsStore is SettingsService (defined in Services/SettingsService.swift)
typealias SettingsStore = SettingsService
