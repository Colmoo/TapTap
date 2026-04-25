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
                Text("TapTap needs Accessibility access so it can listen for trackpad taps anywhere on screen. No keystrokes or personal data are recorded — only left-mouse-down events are observed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(
                    title: "Microphone",
                    description: "Required for acoustic tap side detection (left / centre / right). Only used when \"Microphone side detection\" is enabled in Detection settings.",
                    granted: env.permissions.microphoneGranted,
                    onRequest: { env.permissions.requestMicrophone() },
                    onOpenSettings: { env.permissions.openMicrophoneSettings() }
                )
            } header: {
                Text("Optional Permissions")
            } footer: {
                Text("Audio is processed entirely on-device; no audio is stored or transmitted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { env.permissions.refresh() }
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
