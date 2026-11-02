import SwiftUI

struct DeviceConditionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var manager = DeviceConditionsManager.shared

    var body: some View {
        List {
            Section("Connection") {
                HStack {
                    Label(manager.isConnected ? "Connection responsive" : "Disconnected",
                          systemImage: manager.isConnected ? "checkmark.circle" : "wifi.slash")
                    Spacer()
                    if manager.isBusy { ProgressView() }
                }
                if let lastEnabled = manager.lastEnabled {
                    Text("Last enable acknowledged: \(lastEnabled.groupID) / \(lastEnabled.profileID)")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("No condition enabled in this session")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Connection refresh checks service responsiveness, not the currently induced device state. Verify the actual effect separately (for example, with FLEX).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh Available Conditions") { manager.refresh() }
                    .disabled(manager.isBusy)
            }
            ForEach(manager.groups) { group in
                Section(group.id) {
                    ForEach(group.profiles) { profile in
                        Button {
                            manager.activate(groupID: group.id, profileID: profile.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.title)
                                    if profile.title != profile.id {
                                        Text(profile.id).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if manager.lastEnabled == DeviceConditionSelection(groupID: group.id, profileID: profile.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(manager.isBusy || !manager.isConnected)
                    }
                }
            }
            Section {
                Button("Disable Active Condition") { manager.disable() }
                    .disabled(manager.isBusy || manager.lastEnabled == nil)
                Button("Disconnect Conditions Session") { manager.disconnect() }
                    .disabled(manager.isBusy || !manager.isConnected)
            } footer: {
                Text("Uses the real iOS ConditionInducer service. A successful enable request is not independent verification of the current thermal/GPU/network state. The connection survives leaving this screen; background persistence depends on StikDebug's audio/location keep-alive settings and iOS scheduling. Force-quitting closes the connection; no condition is restored at relaunch.")
            }
        }
        .navigationTitle("Device Conditions")
        .onAppear { manager.connectIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.refresh() }
        }
        .alert("Device Conditions Error", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.dismissError() } }
        )) {
            Button("OK") { manager.dismissError() }
        } message: {
            Text(manager.errorMessage ?? "Unknown error")
        }
    }
}
