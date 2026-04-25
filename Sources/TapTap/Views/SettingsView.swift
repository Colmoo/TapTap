import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        TabView {
            GeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
            BindingsView()
                .tabItem { Label("Bindings", systemImage: "hand.tap.fill") }
            DetectionView()
                .tabItem { Label("Detection", systemImage: "waveform") }
            CalibrationView()
                .tabItem { Label("Calibration", systemImage: "dial.medium") }
            PermissionsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            DebugLogView()
                .tabItem { Label("Debug", systemImage: "terminal") }
        }
        .frame(width: 620, height: 500)
    }
}
