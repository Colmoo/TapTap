import Foundation

/// Which side of the keyboard the tap came from (determined by mic TDOA).
enum TapSide: String, Codable, Sendable {
    case left, center, right
}

enum GestureType: String, Codable, CaseIterable, Identifiable, Sendable {
    // Mic-agnostic (used when mic is disabled, side = .center)
    case single, double, triple
    // Left-side variants (mic required)
    case singleLeft, doubleLeft, tripleLeft
    // Right-side variants (mic required)
    case singleRight, doubleRight, tripleRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single:      "Single Tap"
        case .double:      "Double Tap"
        case .triple:      "Triple Tap"
        case .singleLeft:  "Single Tap — Left"
        case .doubleLeft:  "Double Tap — Left"
        case .tripleLeft:  "Triple Tap — Left"
        case .singleRight: "Single Tap — Right"
        case .doubleRight: "Double Tap — Right"
        case .tripleRight: "Triple Tap — Right"
        }
    }

    var sfSymbol: String {
        switch self {
        case .single:      "1.circle"
        case .double:      "2.circle"
        case .triple:      "3.circle"
        case .singleLeft:  "arrow.left.circle"
        case .doubleLeft:  "arrow.left.circle"
        case .tripleLeft:  "arrow.left.circle"
        case .singleRight: "arrow.right.circle"
        case .doubleRight: "arrow.right.circle"
        case .tripleRight: "arrow.right.circle"
        }
    }

    /// Returns the GestureType for a given tap count and side.
    static func make(count: Int, side: TapSide) -> GestureType {
        switch (count, side) {
        case (_, .center): return count >= 3 ? .triple  : count == 2 ? .double  : .single
        case (_, .left):   return count >= 3 ? .tripleLeft  : count == 2 ? .doubleLeft  : .singleLeft
        case (_, .right):  return count >= 3 ? .tripleRight : count == 2 ? .doubleRight : .singleRight
        }
    }
}

enum ActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcut, shell, app, media, system, url

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortcut: "Apple Shortcut"
        case .shell: "Shell Command"
        case .app: "Launch App"
        case .media: "Media Control"
        case .system: "System Action"
        case .url: "Open URL"
        }
    }

    var placeholder: String {
        switch self {
        case .shortcut: "Shortcut name"
        case .shell: "echo hello"
        case .app: "/Applications/Safari.app"
        case .media: "(choose below)"
        case .system: "(choose below)"
        case .url: "https://example.com"
        }
    }

    var sfSymbol: String {
        switch self {
        case .shortcut: "bolt.fill"
        case .shell: "terminal"
        case .app: "square.grid.2x2"
        case .media: "play.fill"
        case .system: "gearshape.fill"
        case .url: "link"
        }
    }
}

enum MediaCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause = "play-pause"
    case next = "next"
    case previous = "previous"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playPause: "Play / Pause"
        case .next: "Next Track"
        case .previous: "Previous Track"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        }
    }
}

enum SystemCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case lockScreen       = "lock-screen"
    case sleepDisplay     = "sleep-display"
    case toggleMute       = "toggle-mute"
    case toggleDarkMode   = "toggle-dark-mode"
    case screenshotFull   = "screenshot-full"
    case screenshotRegion = "screenshot-region"
    case missionControl   = "mission-control"
    case launchpad        = "launchpad"
    case emptyTrash       = "empty-trash"
    case doNotDisturb     = "do-not-disturb"
    case copy             = "copy"
    case paste            = "paste"
    case undo             = "undo"
    case redo             = "redo"
    case previousDesktop  = "previous-desktop"
    case nextDesktop      = "next-desktop"
    case spotlight        = "spotlight"
    case nextTab          = "next-tab"
    case previousTab      = "previous-tab"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lockScreen:       "Lock Screen"
        case .sleepDisplay:     "Sleep Display"
        case .toggleMute:       "Toggle Mute"
        case .toggleDarkMode:   "Toggle Dark Mode"
        case .screenshotFull:   "Screenshot → Desktop"
        case .screenshotRegion: "Screenshot Region (⇧⌘4)"
        case .missionControl:   "Mission Control"
        case .launchpad:        "Launchpad"
        case .emptyTrash:       "Empty Trash"
        case .doNotDisturb:     "Toggle Do Not Disturb"
        case .copy:             "Copy (⌘C)"
        case .paste:            "Paste (⌘V)"
        case .undo:             "Undo (⌘Z)"
        case .redo:             "Redo (⌘⇧Z)"
        case .previousDesktop:  "Previous Desktop (⌃←)"
        case .nextDesktop:      "Next Desktop (⌃→)"
        case .spotlight:        "Spotlight (⌘Space)"
        case .nextTab:          "Next Tab (⌃⇥)"
        case .previousTab:      "Previous Tab (⌃⇧⇥)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .lockScreen:       "lock.fill"
        case .sleepDisplay:     "display"
        case .toggleMute:       "speaker.slash.fill"
        case .toggleDarkMode:   "moon.fill"
        case .screenshotFull:   "camera.fill"
        case .screenshotRegion: "crop"
        case .missionControl:   "rectangle.3.group.fill"
        case .launchpad:        "square.grid.3x3.fill"
        case .emptyTrash:       "trash.fill"
        case .doNotDisturb:     "moon.zzz.fill"
        case .copy:             "doc.on.doc"
        case .paste:            "doc.on.clipboard"
        case .undo:             "arrow.uturn.backward"
        case .redo:             "arrow.uturn.forward"
        case .previousDesktop:  "arrow.left.square"
        case .nextDesktop:      "arrow.right.square"
        case .spotlight:        "magnifyingglass"
        case .nextTab:          "chevron.right"
        case .previousTab:      "chevron.left"
        }
    }
}

struct GestureBinding: Codable, Identifiable, Sendable {
    var gesture: GestureType
    var actionType: ActionType
    var value: String       // shortcut name, shell cmd, app path, or MediaCommand raw
    var enabled: Bool

    var id: String { gesture.rawValue }

    static var defaults: [GestureBinding] {
        GestureType.allCases.map { gesture in
            GestureBinding(gesture: gesture, actionType: .media, value: MediaCommand.playPause.rawValue, enabled: false)
        }
    }
}

struct AppSettings: Codable, Sendable {
    var doubleTapWindowMs: Double = 300
    var tripleTapWindowMs: Double = 500
    var globalCooldownMs: Double = 1000
    var tapThresholdG: Double = 1.08
    var tapPeakCooldownMs: Double = 50
    var launchAtLogin: Bool = false
    var debugLoggingEnabled: Bool = true
    var mlEnabled: Bool = true
    var mlScoreThreshold: Double = 0.25
    var movementGyroThresholdRadS: Double = 0.5
    var micEnabled: Bool = false
    var micThresholdMultiplier: Double = 6.0
    var micConfirmationEnabled: Bool = false
    var micCorrelationWindowSec: Double = 0.030
    var micUnconfirmedPenalty: Double = 0.5
    var gyroEnergyGateThreshold: Double = 0.0
    var peakValleyCheckEnabled: Bool = false
    var imuSideEnabled: Bool = false

    // MARK: Precision & noise model (new)
    /// −1 (permissive) → +1 (strict). Offsets the auto-derived ML threshold by ±0.15.
    var sensitivityBias: Double = 0.0
    /// Gates both noise model accumulation and its scoring contribution.
    var noiseModelEnabled: Bool = false
    /// True when the user manually moved the mlScoreThreshold slider in Advanced.
    /// Prevents auto-threshold from overwriting it. Reset to false on calibration complete.
    var userOverrodeMLThreshold: Bool = false
    var staLtaEnabled: Bool = true

    // MARK: Backward-compatible decoder

    enum CodingKeys: String, CodingKey {
        case doubleTapWindowMs, tripleTapWindowMs, globalCooldownMs
        case tapThresholdG, tapPeakCooldownMs, launchAtLogin, debugLoggingEnabled
        case mlEnabled, mlScoreThreshold, movementGyroThresholdRadS
        case micEnabled, micThresholdMultiplier
        case micConfirmationEnabled, micCorrelationWindowSec, micUnconfirmedPenalty
        case gyroEnergyGateThreshold, peakValleyCheckEnabled, imuSideEnabled
        case sensitivityBias, noiseModelEnabled, userOverrodeMLThreshold, staLtaEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doubleTapWindowMs         = (try? c.decode(Double.self, forKey: .doubleTapWindowMs))         ?? 300
        tripleTapWindowMs         = (try? c.decode(Double.self, forKey: .tripleTapWindowMs))         ?? 500
        globalCooldownMs          = (try? c.decode(Double.self, forKey: .globalCooldownMs))          ?? 1000
        tapThresholdG             = (try? c.decode(Double.self, forKey: .tapThresholdG))             ?? 1.08
        tapPeakCooldownMs         = (try? c.decode(Double.self, forKey: .tapPeakCooldownMs))         ?? 50
        launchAtLogin             = (try? c.decode(Bool.self,   forKey: .launchAtLogin))             ?? false
        debugLoggingEnabled       = (try? c.decode(Bool.self,   forKey: .debugLoggingEnabled))       ?? true
        mlEnabled                 = (try? c.decode(Bool.self,   forKey: .mlEnabled))                 ?? true
        mlScoreThreshold          = (try? c.decode(Double.self, forKey: .mlScoreThreshold))          ?? 0.25
        movementGyroThresholdRadS = (try? c.decode(Double.self, forKey: .movementGyroThresholdRadS)) ?? 0.5
        micEnabled                = (try? c.decode(Bool.self,   forKey: .micEnabled))                ?? false
        micThresholdMultiplier    = (try? c.decode(Double.self, forKey: .micThresholdMultiplier))    ?? 6.0
        micConfirmationEnabled    = (try? c.decode(Bool.self,   forKey: .micConfirmationEnabled))    ?? false
        micCorrelationWindowSec   = (try? c.decode(Double.self, forKey: .micCorrelationWindowSec))   ?? 0.030
        micUnconfirmedPenalty     = (try? c.decode(Double.self, forKey: .micUnconfirmedPenalty))     ?? 0.5
        gyroEnergyGateThreshold   = (try? c.decode(Double.self, forKey: .gyroEnergyGateThreshold))  ?? 0.0
        peakValleyCheckEnabled    = (try? c.decode(Bool.self,   forKey: .peakValleyCheckEnabled))    ?? false
        imuSideEnabled            = (try? c.decode(Bool.self,   forKey: .imuSideEnabled))            ?? false
        sensitivityBias           = (try? c.decode(Double.self, forKey: .sensitivityBias))           ?? 0.0
        noiseModelEnabled         = (try? c.decode(Bool.self,   forKey: .noiseModelEnabled))         ?? false
        userOverrodeMLThreshold   = (try? c.decode(Bool.self,   forKey: .userOverrodeMLThreshold))   ?? false
        staLtaEnabled             = (try? c.decode(Bool.self,   forKey: .staLtaEnabled))             ?? true
    }
}
