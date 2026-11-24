// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

struct DeviceSelectorView: View {
    @Bindable var appState: AppState
    @State private var viewerError: String?

    private var supportedSimulators: [SimulatorInfo] {
        appState.simulatorManager.simulators.filter {
            $0.supportsAppInteraction
        }
    }

    var body: some View {
        Menu {
            Section(L10n.tr("Simulatoren")) {
                ForEach(supportedSimulators) { sim in
                    Button(action: {
                        Task { await selectSimulator(sim) }
                    }) {
                        HStack {
                            Text(sim.name)
                            if sim.udid == appState.simulatorManager.selectedDeviceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(appState.simulatorManager.isBooting)
                }

                if supportedSimulators.isEmpty {
                    Text(L10n.tr("Keine unterstützten Simulatoren gefunden"))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let udid = appState.simulatorManager.bootedDeviceId {
                if let projectId = appState.activeProjectId,
                   supportedSimulators.contains(where: { $0.udid == udid && $0.deviceTypeIdentifier == SimulatorPose.deviceType }) {
                    Section(L10n.tr("Faltposition")) {
                        ForEach(SimulatorPose.allCases, id: \.self) { pose in
                            Button(pose.label) {
                                Task {
                                    do { try await pose.request(in: appState, projectId: projectId, udid: udid) }
                                    catch { viewerError = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
                Button(L10n.tr("In Xcode öffnen")) {
                    Task {
                        do {
                            try await SimulatorService().openSimulatorApp(udid: udid, inBackground: false)
                        } catch {
                            viewerError = error.localizedDescription
                        }
                    }
                }
            }
            Button(L10n.tr("Geräteliste aktualisieren")) {
                Task { await appState.simulatorManager.loadSimulators() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "iphone")
                if let bootedId = appState.simulatorManager.selectedDeviceID,
                   let sim = appState.simulatorManager.simulators.first(where: { $0.udid == bootedId }) {
                    Text(sim.name)
                        .font(.system(size: 11))
                } else {
                    Text(L10n.tr("Gerät auswählen"))
                        .font(.system(size: 11))
                }
                if appState.simulatorManager.isBooting {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .alert(L10n.tr("Simulator"), isPresented: Binding(
            get: { viewerError != nil }, set: { if !$0 { viewerError = nil } }
        )) {} message: {
            Text(viewerError ?? "")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.tr("Simulator für dieses Projekt auswählen und merken"))
    }

    private func selectSimulator(_ sim: SimulatorInfo) async {
        await appState.startProjectSimulator(selecting: sim.udid)
    }
}
