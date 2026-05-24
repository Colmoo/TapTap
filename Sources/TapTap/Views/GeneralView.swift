import SwiftUI
import ServiceManagement

struct GeneralView: View {
    @Environment(AppEnvironment.self) var env
    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status

    private var isRegistered: Bool { loginItemStatus == .enabled }
    private var needsApproval: Bool { loginItemStatus == .requiresApproval }

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Start TapTap at login", isOn: Binding(
                    get: { env.store.settings.launchAtLogin },
                    set: { v in
                        var s = env.store.settings
                        s.launchAtLogin = v
                        env.store.update(settings: s)
                        env.applySettings()
                        loginItemStatus = SMAppService.mainApp.status
                    }
                ))

                if needsApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval required")
                                .font(.caption.weight(.semibold))
                            Text("Open System Settings → General → Login Items and enable TapTap.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Section("Advanced") {
                Toggle("Enable debug logging", isOn: Binding(
                    get: { env.store.settings.debugLoggingEnabled },
                    set: { v in
                        var s = env.store.settings
                        s.debugLoggingEnabled = v
                        env.store.update(settings: s)
                        env.applySettings()
                    }
                ))
                Text("Logs tap detections, filtering actions, and command executions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            loginItemStatus = SMAppService.mainApp.status
            // Sync stored setting to real system status
            let reallyEnabled = loginItemStatus == .enabled
            if env.store.settings.launchAtLogin != reallyEnabled {
                var s = env.store.settings
                s.launchAtLogin = reallyEnabled
                env.store.update(settings: s)
            }
        }
    }
}
