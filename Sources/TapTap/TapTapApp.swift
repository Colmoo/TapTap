import SwiftUI

@main
struct TapTapApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        // Menu bar item — no Dock icon when this is the only scene with no WindowGroup
        MenuBarExtra {
            AppMenuView()
                .environment(env)
        } label: {
            let icon = env.isListening ? "hand.tap.fill" : "hand.tap"
            Label("TapTap", systemImage: icon)
        }

        // Settings window (Cmd+, or "Open Settings…" from menu)
        Settings {
            SettingsView()
                .environment(env)
        }
    }
}

struct AppMenuView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Listening toggle at the top of the menu
        Button {
            env.toggleListening()
        } label: {
            Label(
                env.isListening ? "Stop Listening" : "Start Listening",
                systemImage: env.isListening ? "stop.circle" : "play.circle"
            )
        }

        if let last = env.lastGesture {
            Text("Last: \(last.displayName)")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open Settings…") {
            openSettings()
            // Bring settings window to front
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit TapTap") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
