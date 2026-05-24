import SwiftUI

enum SettingsCategory: String, CaseIterable, Hashable {
    case general, bindings, detection, calibration, permissions, debug

    var title: String {
        switch self {
        case .general:     "General"
        case .bindings:    "Bindings"
        case .detection:   "Detection"
        case .calibration: "Calibration"
        case .permissions: "Permissions"
        case .debug:       "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general:     "gearshape"
        case .bindings:    "hand.tap.fill"
        case .detection:   "waveform"
        case .calibration: "dial.medium"
        case .permissions: "lock.shield"
        case .debug:       "terminal"
        }
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selection: SettingsCategory? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, id: \.self, selection: $selection) { category in
                Label(category.title, systemImage: category.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            switch selection ?? .general {
            case .general:     GeneralView()
            case .bindings:    BindingsView()
            case .detection:   DetectionView()
            case .calibration: CalibrationView()
            case .permissions: PermissionsView()
            case .debug:       DebugLogView()
            }
        }
        .frame(minWidth: 740, minHeight: 460)
    }
}
