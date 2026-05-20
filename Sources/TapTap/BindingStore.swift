import Foundation
import Observation

@Observable
@MainActor
final class BindingStore {
    private(set) var bindings: [GestureType: GestureBinding] = [:]
    private(set) var settings: AppSettings = AppSettings()

    private let bindingsKey = "TapTap.bindings"
    private let settingsKey = "TapTap.settings"
    // Use explicit suite so both the .app bundle and `swift run` (no bundle ID) read the same plist.
    private let defaults = UserDefaults(suiteName: "com.colmo.TapTap") ?? .standard

    init() {
        load()
    }

    func binding(for gesture: GestureType) -> GestureBinding? {
        bindings[gesture]
    }

    func allBindings() -> [GestureBinding] {
        GestureType.allCases.compactMap { bindings[$0] }
    }

    func update(_ binding: GestureBinding) {
        bindings[binding.gesture] = binding
        save()
    }

    func update(settings: AppSettings) {
        self.settings = settings
        save()
    }

    // MARK: - Persistence

    private func save() {
        let list = Array(bindings.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: bindingsKey)
        }
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: bindingsKey),
           let list = try? JSONDecoder().decode([GestureBinding].self, from: data) {
            for b in list { bindings[b.gesture] = b }
        } else {
            for b in GestureBinding.defaults { bindings[b.gesture] = b }
        }

        if let data = defaults.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        }
    }
}
