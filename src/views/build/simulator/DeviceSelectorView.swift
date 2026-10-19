import SwiftUI

struct DeviceSelectorView: View {
    @Bindable var appState: AppState

    private var supportedSimulators: [SimulatorInfo] {
        appState.simulatorManager.simulators.filter {
            SimulatorConfigDatabase.isSupported($0.displayName)
        }
    }

    var body: some View {
        Menu {
            Section("Simulators") {
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
                    Text("No supported simulators found")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Refresh Devices") {
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
                    Text("Select Device")
                        .font(.system(size: 11))
                }
                if appState.simulatorManager.isBooting {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose and remember a simulator for this project")
    }

    private func selectSimulator(_ sim: SimulatorInfo) async {
        await appState.startProjectSimulator(selecting: sim.udid)
    }
}
