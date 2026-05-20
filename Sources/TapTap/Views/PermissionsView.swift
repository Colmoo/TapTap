import SwiftUI

struct PermissionsView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required to monitor global tap events across all apps.",
                    granted: env.permissions.accessibilityGranted,
                    onRequest: { env.permissions.requestAccessibility() },
                    onOpenSettings: { env.permissions.openAccessibilitySettings() }
                )
            } header: {
                Text("Required Permissions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TapTap needs Accessibility access so it can listen for tap gestures anywhere on screen. No keystrokes or personal data are recorded.")
                    if !env.permissions.accessibilityGranted {
                        Text("If System Settings shows TapTap as enabled but it still appears denied here, toggle the switch off then back on, then click Refresh.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear { env.permissions.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            env.permissions.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh") { env.permissions.refresh() }
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: granted ? "checkmark.shield.fill" : "xmark.shield")
                    .foregroundStyle(granted ? .green : .red)
                Text(title).bold()
                Spacer()
                if granted {
                    Text("Granted")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.1), in: Capsule())
                } else {
                    Button("Grant Access", action: onRequest)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !granted {
                Button("Open System Settings…", action: onOpenSettings)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
