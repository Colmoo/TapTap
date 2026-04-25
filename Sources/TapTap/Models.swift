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
    /// How long after the first tap to wait for a second tap (ms)
    var doubleTapWindowMs: Double = 300
    /// How long after the second tap to wait for a third tap (ms)
    var tripleTapWindowMs: Double = 500
    /// Minimum time between gesture fires (ms)
    var globalCooldownMs: Double = 1000
    /// Acceleration magnitude (g-force) that triggers a tap event.
    /// At rest the device reads ~1 g; a light knock typically peaks at 1.05–1.15 g.
    var tapThresholdG: Double = 1.08
    /// Minimum time (ms) between consecutive tap events (suppresses vibration echo).
    var tapPeakCooldownMs: Double = 50
    var launchAtLogin: Bool = false
    var debugLoggingEnabled: Bool = true
    /// Whether to apply the Gaussian ML filter when calibration data is available.
    var mlEnabled: Bool = true
    /// Minimum match score [0–1] for a tap event to pass the ML gate.
    /// Lower = more permissive (catch light/off-centre taps); higher = stricter.
    var mlScoreThreshold: Double = 0.25
    /// Peak gyroscope magnitude (rad/s) above which an event is classified as
    /// whole-laptop movement and rejected.  0 = filter disabled.
    var movementGyroThresholdRadS: Double = 0.5

    // MARK: Microphone / TDOA side detection
    /// Enable acoustic tap side detection via the built-in stereo microphones.
    var micEnabled: Bool = false
    /// Peak amplitude must exceed noiseFloor × this multiplier to register.
    var micThresholdMultiplier: Double = 6.0
    /// |TDOA| below this value (ms) is classified as a centre tap.
    /// Max possible TDOA on a MacBook (~28 cm keyboard) ≈ 0.82 ms.
    var micSideThresholdMs: Double = 0.2

    // MARK: Microphone / IMU confirmation gate
    /// When enabled, every IMU tap event is cross-checked against recent mic
    /// transients.  Events with no matching acoustic transient are downgraded
    /// by `micUnconfirmedPenalty` before passing through the ML gate.
    ///
    /// Effect: lets you lower `tapThresholdG` to catch lighter taps while the
    /// mic vetos false positives (table bumps, typing vibrations) that move the
    /// IMU but produce no matching acoustic signature near the microphones.
    var micConfirmationEnabled: Bool = false
    /// Half-width (seconds) of the acoustic correlation window centred on the
    /// IMU event timestamp.  Genuine taps arrive at both sensors within ~10–20 ms;
    /// 30 ms provides headroom without catching unrelated ambient sounds.
    var micCorrelationWindowSec: Double = 0.030
    /// Score multiplier applied when no acoustic transient is found within the
    /// correlation window.  0 = always reject unconfirmed events; 1 = no effect.
    /// Default 0.5 halves the effective ML score, vetoing borderline events while
    /// still letting through high-confidence IMU hits (e.g. forceful knocks).
    var micUnconfirmedPenalty: Double = 0.5

    // MARK: IMU signal processing upgrades (Steps 1–10)

    /// Step 2 — minimum summed gyro energy (Σω²) accumulated during the tracking
    /// window before a tap is accepted.  Typing rarely couples into rotation, so
    /// this gate eliminates most false positives at zero ML cost.
    /// 0 = disabled (default, backwards-compatible).
    var gyroEnergyGateThreshold: Double = 0.0

    /// Step 3 — when true, require the differentiated z-axis signal to have a
    /// characteristic rebound valley within 30 ms of the peak (ratio 0.15–0.95).
    /// Rejects noise and slow desk bumps that lack a physical impact rebound.
    /// Disabled by default; enable after verifying it doesn't drop genuine taps.
    var peakValleyCheckEnabled: Bool = false

    /// Step 10 — when true, use the IMU cross-axis correlation / rotational impulse
    /// features together with a trained `SideCalibrationData` centroid model to
    /// assign `.left` / `.right` / `.center` to each tap without the microphone.
    /// Requires running side calibration in CalibrationManager first.
    var imuSideEnabled: Bool = false
}
