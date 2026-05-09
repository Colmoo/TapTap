import SwiftUI

// MARK: - Main view

struct BindingsView: View {
    @Environment(AppEnvironment.self) var env
    @State private var editingGesture: GestureType? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                KeyboardMapView(editingGesture: $editingGesture)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if !(env.store.settings.micEnabled || env.store.settings.imuSideEnabled) {
                    MicUpsellBanner()
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 16)
            }
        }
        .sheet(item: $editingGesture) { gesture in
            BindingEditorSheet(gesture: gesture)
                .environment(env)
        }
    }
}

// MARK: - Keyboard map

struct KeyboardMapView: View {
    @Environment(AppEnvironment.self) var env
    @Binding var editingGesture: GestureType?

    var sideEnabled: Bool {
        env.store.settings.micEnabled || env.store.settings.imuSideEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Tap Zones")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if sideEnabled {
                    Label("9 gestures", systemImage: env.store.settings.micEnabled ? "mic.fill" : "gyroscope")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                } else {
                    Label("3 gestures", systemImage: "hand.tap")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
            }

            HStack(spacing: 0) {
                TapZoneColumn(
                    side: .left,
                    active: sideEnabled,
                    editingGesture: $editingGesture
                )

                Divider()

                TapZoneColumn(
                    side: .center,
                    active: true,
                    editingGesture: $editingGesture
                )

                Divider()

                TapZoneColumn(
                    side: .right,
                    active: sideEnabled,
                    editingGesture: $editingGesture
                )
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        }
    }
}

// MARK: - Tap zone column

struct TapZoneColumn: View {
    @Environment(AppEnvironment.self) var env
    let side: TapSide
    let active: Bool
    @Binding var editingGesture: GestureType?

    var title: String {
        switch side {
        case .left:   "Left"
        case .center: "Center"
        case .right:  "Right"
        }
    }

    var icon: String {
        switch side {
        case .left:   "arrow.backward"
        case .center: "hand.tap"
        case .right:  "arrow.forward"
        }
    }

    var gestures: [(tapCount: Int, type: GestureType)] {
        (1...3).map { n in (n, GestureType.make(count: n, side: side)) }
    }

    var configuredCount: Int {
        gestures.filter { env.store.binding(for: $0.type)?.enabled == true }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Zone header
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
                if active && configuredCount > 0 {
                    Spacer()
                    Text("\(configuredCount)/3")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .foregroundStyle(active ? Color.primary.opacity(0.6) : Color.primary.opacity(0.25))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.fill.tertiary)

            Divider()

            // Gesture rows
            VStack(spacing: 0) {
                ForEach(gestures, id: \.type) { item in
                    GestureSlotButton(
                        gesture: item.type,
                        tapCount: item.tapCount,
                        isZoneActive: active
                    ) {
                        guard active else { return }
                        editingGesture = item.type
                    }

                    if item.tapCount < 3 {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .opacity(active ? 1 : 0.4)
        .overlay {
            if !active {
                VStack(spacing: 6) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 18))
                    Text("Side off")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Gesture slot button

struct GestureSlotButton: View {
    @Environment(AppEnvironment.self) var env
    let gesture: GestureType
    let tapCount: Int
    let isZoneActive: Bool
    let action: () -> Void

    var binding: GestureBinding? { env.store.binding(for: gesture) }
    var isConfigured: Bool { binding?.enabled == true }

    var countLabel: String {
        switch tapCount {
        case 1: "Single tap"
        case 2: "Double tap"
        case 3: "Triple tap"
        default: "\(tapCount)× tap"
        }
    }

    var subtitleText: String {
        guard let b = binding, b.enabled else { return "Not configured" }
        switch b.actionType {
        case .media:
            return MediaCommand(rawValue: b.value)?.displayName ?? b.value
        case .system:
            return SystemCommand(rawValue: b.value)?.displayName ?? b.value
        case .app:
            let name = URL(fileURLWithPath: b.value).deletingPathExtension().lastPathComponent
            return name.isEmpty ? b.value : name
        case .shortcut:
            return b.value.isEmpty ? "Apple Shortcut" : b.value
        case .shell:
            return b.value.isEmpty ? "Shell command" : b.value
        case .url:
            return b.value.isEmpty ? "URL" : b.value
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Tap-count dots
                TapDots(count: tapCount, filled: isConfigured)
                    .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(countLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(subtitleText)
                        .font(.caption2)
                        .foregroundStyle(isConfigured ? .secondary : .tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isConfigured ? Color.accentColor.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isZoneActive)
    }
}

// MARK: - Tap dots indicator

struct TapDots: View {
    let count: Int
    let filled: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(filled ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Mic upsell banner

struct MicUpsellBanner: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Unlock Left & Right Zones")
                    .font(.subheadline.weight(.semibold))
                Text("Enable mic detection or IMU side calibration (Detection tab) to get 9 gestures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 6) {
                Button("Enable Mic") {
                    var s = env.store.settings
                    s.micEnabled = true
                    env.store.update(settings: s)
                    env.applySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Enable IMU") {
                    var s = env.store.settings
                    s.imuSideEnabled = true
                    env.store.update(settings: s)
                    env.applySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.blue.opacity(0.15), lineWidth: 1)
        }
    }
}

// MARK: - Binding editor sheet

struct BindingEditorSheet: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss
    let gesture: GestureType

    @State private var actionType: ActionType = .media
    @State private var value: String = ""
    @State private var enabled: Bool = false
    @State private var mediaCommand: MediaCommand = .playPause
    @State private var systemCommand: SystemCommand = .lockScreen

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack(alignment: .center, spacing: 12) {
                TapDots(count: tapCount(for: gesture), filled: enabled)
                    .scaleEffect(1.4)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.displayName)
                        .font(.headline)
                    Text(zoneName(for: gesture))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .onChange(of: enabled) { _, _ in save() }
                    .help(enabled ? "Disable this gesture" : "Enable this gesture")

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if !enabled {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("This gesture is currently disabled and will not fire.")
                }
                .font(.caption2)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.1))
                .foregroundStyle(.orange)
            }

            Divider()

            Form {
                Section("Action Type") {
                    Picker("", selection: $actionType) {
                        ForEach(ActionType.allCases) { type in
                            Label(type.displayName, systemImage: type.sfSymbol).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: actionType) { _, newType in
                        switch newType {
                        case .media:  value = mediaCommand.rawValue
                        case .system: value = systemCommand.rawValue
                        default: break
                        }
                        save()
                    }
                }

                Section {
                    switch actionType {
                    case .media:
                        Picker("Command", selection: $mediaCommand) {
                            ForEach(MediaCommand.allCases) { cmd in
                                Text(cmd.displayName).tag(cmd)
                            }
                        }
                        .pickerStyle(.inline)
                        .onChange(of: mediaCommand) { _, cmd in
                            value = cmd.rawValue
                            save()
                        }

                    case .system:
                        Picker("Command", selection: $systemCommand) {
                            ForEach(SystemCommand.allCases) { cmd in
                                Label(cmd.displayName, systemImage: cmd.sfSymbol).tag(cmd)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: systemCommand) { _, cmd in
                            value = cmd.rawValue
                            save()
                        }

                    case .app:
                        HStack {
                            TextField("App path", text: $value)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { save() }
                            Button("Choose…") { pickApp() }
                                .buttonStyle(.borderless)
                        }

                    default:
                        TextField(actionType.placeholder, text: $value)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                    }

                    Button {
                        testCurrent()
                    } label: {
                        Label("Test Action Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                } footer: {
                    if isKeyboardAction && !env.permissions.accessibilityGranted {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Requires Accessibility Access", systemImage: "exclamationmark.shield.fill")
                                .foregroundStyle(.red)
                                .font(.caption.bold())
                            
                            Text("This action simulates keyboard input and requires permission to work globally.")
                                .font(.caption2)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 520)
        .onAppear { loadFromStore() }
    }

    // MARK: - Helpers

    private var isKeyboardAction: Bool {
        switch actionType {
        case .system:
            guard let cmd = SystemCommand(rawValue: value) else { return false }
            switch cmd {
            case .lockScreen, .screenshotRegion, .copy, .paste, .undo, .redo, 
                 .previousDesktop, .nextDesktop, .spotlight, .nextTab, .previousTab:
                return true
            default: return false
            }
        default: return false
        }
    }

    private func testCurrent() {
        let resolvedValue: String
        switch actionType {
        case .media:  resolvedValue = mediaCommand.rawValue
        case .system: resolvedValue = systemCommand.rawValue
        default:      resolvedValue = value
        }
        
        let tempBinding = GestureBinding(
            gesture: gesture,
            actionType: actionType,
            value: resolvedValue,
            enabled: true // testing overrides local enabled flag
        )
        env.testAction(binding: tempBinding)
    }

    private func tapCount(for g: GestureType) -> Int {
        switch g {
        case .single, .singleLeft, .singleRight: return 1
        case .double, .doubleLeft, .doubleRight: return 2
        case .triple, .tripleLeft, .tripleRight: return 3
        }
    }

    private func zoneName(for g: GestureType) -> String {
        switch g {
        case .single, .double, .triple:           return "Center zone"
        case .singleLeft, .doubleLeft, .tripleLeft:   return "Left zone"
        case .singleRight, .doubleRight, .tripleRight: return "Right zone"
        }
    }

    private func loadFromStore() {
        guard let b = env.store.binding(for: gesture) else { return }
        actionType    = b.actionType
        value         = b.value
        enabled       = b.enabled
        mediaCommand  = MediaCommand(rawValue: b.value)  ?? .playPause
        systemCommand = SystemCommand(rawValue: b.value) ?? .lockScreen
    }

    private func save() {
        let resolvedValue: String
        switch actionType {
        case .media:  resolvedValue = mediaCommand.rawValue
        case .system: resolvedValue = systemCommand.rawValue
        default:      resolvedValue = value
        }
        env.store.update(GestureBinding(
            gesture: gesture,
            actionType: actionType,
            value: resolvedValue,
            enabled: enabled
        ))
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            value = url.path
            save()
        }
    }
}
