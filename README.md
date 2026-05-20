# TapTap

**TapTap** is a macOS menu bar utility that turns physical taps on your MacBook chassis into fully customisable actions — no trackpad click, no keyboard shortcut. Tap once, twice, or three times anywhere on the body of your Mac and trigger Apple Shortcuts, shell commands, media controls, system actions, app launches, or URLs.

It runs silently in the background and consumes negligible CPU at rest.

---

## How It Works

TapTap reads the Apple Silicon built-in IMU (accelerometer + gyroscope) via the IOKit HID interface at ~200 Hz. When the raw Z-axis acceleration exceeds a configurable threshold it registers a raw tap event. A debounce classifier then groups rapid successive taps into single / double / triple gestures, optionally combined with a left / centre / right chassis zone — giving up to **9 bindable gestures**.

```
IOKit HID (C)           Swift layer
─────────────           ──────────────────────────────────────────────────────
tap_accel.c   ────────▶ TapInputService  ──┐
(200 Hz poll)           (threshold + ML)   ├──▶ GestureClassifier ──▶ ActionExecutor
                                            │    (debounce, count,      (shortcut / shell /
                                            │     side classify)         app / media / system)
                                            │
                                           AppEnvironment  ← SwiftUI @Observable root
                                           BindingStore    ← UserDefaults persistence
                                           EventLogger     ← in-memory log ring
```

### Tap detection pipeline

1. **IMU poll** — `tap_accel.c` polls the HID device every 5 ms and fires a callback on the main run loop whenever the Z-axis crosses `tapThresholdG`.
2. **ML gate** — `GestureClassifier` runs a lightweight score (STA/LTA ratio) to reject motion noise. The threshold auto-tunes after calibration; a sensitivity bias slider lets you nudge it ±0.15.
3. **Gyro gate** — rapid rotation (e.g. picking up the Mac) suppresses false positives via a configurable rad/s threshold.
4. **Debounce** — a first tap starts a 300 ms window; each subsequent tap resets it to 500 ms. When the timer fires the accumulated count → `.single` / `.double` / `.triple`.
5. **Side classification** (optional) — a 3-class Mahalanobis distance model trained during side calibration maps each tap to `.left` / `.centre` / `.right`, yielding 9 gesture slots.
6. **Action dispatch** — `ActionExecutor` runs the bound action asynchronously.

---

## Gesture Types

| Gesture | Available when |
|---------|---------------|
| Single Tap | Always |
| Double Tap | Always |
| Triple Tap | Always |
| Single / Double / Triple Tap — Left | IMU side detection enabled & calibrated |
| Single / Double / Triple Tap — Right | IMU side detection enabled & calibrated |

Centre taps (the standard 3) are always available. Enabling **IMU Side Detection** and completing the side calibration unlocks all 9 slots.

---

## Action Types

| Type | What it does |
|------|-------------|
| **Apple Shortcut** | Runs a named shortcut via `/usr/bin/shortcuts run <name>` |
| **Shell Command** | Executes an arbitrary shell command via `/bin/zsh -c <cmd>` |
| **Launch App** | Opens an app bundle via `NSWorkspace.shared.open` |
| **Media Control** | Play/Pause · Next · Previous · Volume Up · Volume Down |
| **System Action** | Lock Screen · Sleep Display · Toggle Mute · Toggle Dark Mode · Screenshot · Mission Control · Launchpad · Spotlight · Desktop switching · Tabs · Do Not Disturb · Copy/Paste/Undo/Redo · Empty Trash |
| **Open URL** | Opens any URL in the default browser |

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Apple Silicon** Mac (M1 or later) — the IMU HID interface is Apple Silicon only
- **Accessibility permission** — required to execute system actions and keyboard shortcuts
- **Automation permission** — required for Apple Shortcuts and some system commands

---

## Building & Running

TapTap is an **Swift Package Manager** project with no Xcode project file. It must be run as a `.app` bundle — the raw binary from `.build/` will not show a menu bar icon.

```bash
# Quick debug build (fast iteration)
swift build

# Build the full .app bundle (recommended)
bash build-app.sh        # outputs TapTap.app in the project root

# Launch
open TapTap.app

# Install to Applications (optional)
cp -r TapTap.app /Applications/
```

`build-app.sh` compiles in release mode, assembles the bundle, copies `Info.plist`, and ad-hoc code-signs it so macOS accessibility permissions are stable.

---

## Project Structure

```
TapTap/
├── Sources/
│   ├── TapTapC/                   # C module — IOKit HID IMU polling
│   │   ├── tap_accel.c            # 200 Hz poll loop, callback on tap threshold
│   │   └── include/tap_accel.h
│   └── TapTap/                    # Swift / SwiftUI application
│       ├── AppEnvironment.swift   # @Observable root, owns all services
│       ├── BindingStore.swift     # UserDefaults persistence (bindings + settings)
│       ├── EventLogger.swift      # In-memory ring buffer for the debug log view
│       ├── Models.swift           # GestureType, ActionType, GestureBinding, AppSettings
│       ├── TapWindow.swift        # NSWindow / SwiftUI hosting wrapper
│       ├── Services/
│       │   ├── TapInputService.swift      # IMU tap event ingestion & ML gating
│       │   ├── GestureClassifier.swift    # Debounce + side-lock gesture accumulator
│       │   ├── ActionExecutor.swift       # Action dispatch (shortcuts, shell, media…)
│       │   ├── CalibrationManager.swift   # Side calibration data collection & model fit
│       │   └── PermissionManager.swift    # Accessibility / Automation permission checks
│       ├── Views/
│       │   ├── BindingsView.swift         # Tap zone map + binding editor sheet
│       │   ├── DetectionView.swift        # Live tap visualiser + sensitivity controls
│       │   ├── CalibrationView.swift      # Step-by-step side calibration wizard
│       │   ├── SettingsView.swift         # Tabbed settings host
│       │   ├── GeneralView.swift          # General settings (timing, launch at login)
│       │   ├── PermissionsView.swift      # Permission status & refresh
│       │   └── DebugLogView.swift         # Scrollable event log
│       └── Info.plist             # LSUIElement=YES, bundle metadata
├── Package.swift
├── build-app.sh
└── TapTap.app/                    # Pre-built app bundle (tracked for convenience)
```

---

## Key Tuning Constants

### IMU / Detection

| Setting | Default | Purpose |
|---------|---------|---------|
| `tapThresholdG` | `1.08 g` | Z-axis acceleration above resting (~1 g) that counts as a tap |
| `tapPeakCooldownMs` | `50 ms` | Suppresses vibration echo immediately after a tap |
| `doubleTapWindowMs` | `300 ms` | Window to accumulate a second tap |
| `tripleTapWindowMs` | `500 ms` | Window to accumulate a third tap |
| `globalCooldownMs` | `1000 ms` | Minimum gap between gesture fires |
| `movementGyroThresholdRadS` | `0.5 rad/s` | Gyro gate — suppress taps when the Mac is rotating |
| `sensitivityBias` | `0.0` | Shifts the ML score threshold ±0.15 (–1 permissive → +1 strict) |
| `mlScoreThreshold` | `0.25` | Raw ML confidence gate (auto-set after calibration) |
| `staLtaEnabled` | `true` | STA/LTA ratio pre-filter for soft tap rejection |

### IMU internals (C layer)

| Constant | Value | Purpose |
|----------|-------|---------|
| `POLL_INTERVAL` | `0.005 s` | Timer interval (~200 Hz) |
| `ACCEL_OFFSET` | `6` | Byte offset of first int32 axis in the 22-byte HID report |
| `ACCEL_SCALE` | `65536.0` | Q16.16 → g-force divisor |

---

## Side Calibration

When **IMU Side Detection** is enabled in the Bindings tab, TapTap classifies each tap as left / centre / right using a per-device Mahalanobis distance model. The model must be trained once per machine.

**Calibration steps:**

1. Open **Bindings → Start Calibration**.
2. Tap the **left** side of the keyboard 30 times when prompted.
3. Tap the **right** side of the keyboard 30 times.
4. Tap the **centre / trackpad** area 30 times.
5. TapTap fits a 3-class covariance model and stores it to `UserDefaults`.

After calibration the 9-gesture layout unlocks. Recalibrate if accuracy degrades (e.g. after using the Mac on different surfaces).

---

## Permissions

TapTap requests two permissions at launch:

- **Accessibility** — needed to execute keyboard shortcuts, desktop switching, and most system actions. Grant in *System Settings → Privacy & Security → Accessibility*.
- **Automation** — needed to run Apple Shortcuts via the `shortcuts` CLI. Granted automatically on first use.

The **Permissions** tab shows live status and refreshes every 2 seconds. If permissions appear stuck, use the *Open System Settings* button and toggle TapTap off then on.

---

## Architecture Notes

- All Swift code runs on `@MainActor`. The only exception is `TapInputService.handleSample`, which is `nonisolated` because C callbacks carry no actor context — it immediately hops back via `Task { @MainActor }`.
- The HID device is **event-driven at rest** — it does not push reports on chassis taps. The C layer polls via `CFRunLoopTimer` and calls `IOHIDDeviceGetReport` every 5 ms.
- `BindingStore` serialises both `[GestureType: GestureBinding]` and `AppSettings` as JSON to `UserDefaults`. The decoder is backward-compatible — unknown keys are silently ignored, missing keys fall back to defaults.
- `ActionExecutor` uses AppleScript (`osascript`) for desktop space switching and app focusing, because `CGEvent`-based synthetic key events are unreliable in sandboxed / SIP contexts.
- The app sets `LSUIElement = YES` in `Info.plist` to hide the Dock icon; the only UI entry point is the menu bar icon.

---

## License

MIT — see [`LICENSE`](LICENSE) if present, otherwise consider it free to use and modify.
