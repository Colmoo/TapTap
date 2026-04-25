# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Debug build (fast, for iteration)
swift build

# Create a runnable .app bundle (release build)
bash build-app.sh        # outputs TapTap.app in the project root
open TapTap.app

# Install to Applications
cp -r TapTap.app /Applications/
```

The app **must** be run as a `.app` bundle — running the raw binary from `.build/` will not show the menu bar icon. `build-app.sh` handles the bundle creation automatically.

There are no tests and no linter configured.

## Architecture

The pipeline is: **IMU + Mic → TapInputService / MicInputService → GestureClassifier → ActionExecutor**

```
IOKit HID (C)          Swift layer
─────────────          ─────────────────────────────────────────────────────
tap_accel.c   ──────▶  TapInputService  ──┐
(poll loop)            (threshold filter)  ├──▶  GestureClassifier  ──▶  ActionExecutor
                                           │     (debounce, count,        (shortcut/shell/app/media)
AVAudioEngine ──────▶  MicInputService  ──┘      side classification)
(stereo PCM)           (TDOA, high-pass)
                                │
                                ▼
                           AppEnvironment   ← SwiftUI @Observable root
                           BindingStore     ← UserDefaults persistence
                           EventLogger      ← in-memory log ring
```

### MicInputService (Swift — AVAudioEngine)
`Sources/TapTap/Services/MicInputService.swift` — detects taps acoustically via the MacBook's built-in stereo microphones and determines which **side** of the keyboard was struck using Time Difference of Arrival (TDOA). Approach derived from [SurfaceTap](https://github.com/kdv123/SurfaceTap).

**Pipeline:**
1. **Capture** — `AVAudioEngine` with `inputNode` tap at 48 kHz, stereo (channels 0 = left, 1 = right).
2. **High-pass filter** — Butterworth-style IIR at ~150 Hz cutoff removes low-frequency rumble and keystroke noise; preserves the sharp transient of a tap (implemented via `AVAudioUnitEQ` or manual biquad coefficients).
3. **Peak detection** — per-channel energy exceeds `noiseFloor * micThresholdMultiplier`. `noiseFloor` is estimated from a rolling RMS of quiet frames.
4. **TDOA** — record the sample timestamp of the first threshold-crossing peak in each channel. `tdoa = t_left − t_right` (positive = left side first; negative = right side first).
5. **Side classification** — compare `|tdoa|` against `micSideThresholdMs`:
   - `|tdoa| < threshold` → `.center`
   - `tdoa > 0` → `.left`
   - `tdoa < 0` → `.right`
6. **Emit** — calls `onTap(side:)` callback which feeds `GestureClassifier` alongside IMU taps.

**Physical basis:**
- MacBook keyboard width ≈ 28 cm; speed of sound ≈ 343 m/s.
- Maximum possible TDOA ≈ 0.28 / 343 ≈ **0.82 ms** (~39 samples at 48 kHz).
- Center-tap threshold should be ≤ 0.2 ms to avoid false side assignments.

**Permissions:**
- Requires `NSMicrophoneUsageDescription` in `Info.plist` and a run-time `AVCaptureDevice.requestAccess(for: .audio)` prompt.
- The existing `PermissionManager` should be extended to check/request microphone access before `MicInputService` starts.

### TapTapC (C module)
`Sources/TapTapC/tap_accel.c` — reads the Apple Silicon IMU via IOKit HID.

- Matches HID device at `PrimaryUsagePage=0xFF00`, `PrimaryUsage=0x0003` (vendor-specific, NOT the standard HID sensor page).
- The device is **event-driven and silent at rest** — it does not push reports on chassis taps. A `CFRunLoopTimer` fires every 5 ms and calls `IOHIDDeviceGetReport` to poll the current state at ~200 Hz.
- Report layout (22 bytes): bytes 6–9 = X axis int32 LE Q16.16; bytes 10–13 = Y; bytes 14–17 = Z. Divide by 65536 to get g-force. Z ≈ −1 g at rest.
- C callback fires on the main run loop via `CFRunLoopGetMain()`, so Swift `@MainActor` access is safe without extra dispatch.

### Swift/SwiftUI layer
All Swift code is `@MainActor`. The only exception is `TapInputService.handleSample`, which is `nonisolated` because C callbacks can't carry actor context — it hops back to `@MainActor` immediately via `Task { @MainActor }`.

- **`AppEnvironment`** — `@Observable` root object injected through SwiftUI environment. Owns all services and wires the pipeline in `wireUpPipeline()`. Call `applySettings()` after any `AppSettings` change to push new values into services.
- **`GestureClassifier`** — counts raw taps within a sliding window. First tap starts a `doubleTapWindow` timer; each additional tap resets it to `tripleTapWindow`. Timer expiry classifies the accumulated count into `.single/.double/.triple`. A `cooldown` prevents re-firing during ring-down.
- **`BindingStore`** — persists `[GestureType: GestureBinding]` and `AppSettings` to `UserDefaults` as JSON.
- **`ActionExecutor`** — executes the bound action asynchronously: runs `/usr/bin/shortcuts run <name>` for Apple Shortcuts, `/bin/zsh -c <cmd>` for shell, `NSWorkspace.shared.open` for apps, `CGEvent`-based NX media key pairs for media control.

### App bundle
Because this is an SPM executable (not an Xcode project), a proper `.app` bundle is assembled by `build-app.sh`. The `Info.plist` at `Sources/TapTap/Info.plist` includes `LSUIElement=YES` (hides Dock icon) and `NSPrincipalClass=NSApplication`. It is excluded from the SPM target via `Package.swift` and copied into `TapTap.app/Contents/` by the script.

## Key constants & tuning knobs

### IMU (existing)
| Location | Symbol | Default | Purpose |
|---|---|---|---|
| `tap_accel.c` | `POLL_INTERVAL` | `0.005` (5 ms) | IMU poll rate |
| `tap_accel.c` | `ACCEL_OFFSET` | `6` | Byte offset of first int32 axis in report |
| `tap_accel.c` | `ACCEL_SCALE` | `65536.0` | Q16.16 → g-force divisor |
| `Models.swift` `AppSettings` | `tapThresholdG` | `1.4` | g-force above resting (~1 g) that counts as a tap |
| `Models.swift` `AppSettings` | `tapPeakCooldownMs` | `50` | Suppress vibration echo after a tap |
| `Models.swift` `AppSettings` | `doubleTapWindowMs` | `300` | Window to accumulate a second tap |
| `Models.swift` `AppSettings` | `tripleTapWindowMs` | `500` | Window to accumulate a third tap |
| `Models.swift` `AppSettings` | `globalCooldownMs` | `1000` | Minimum gap between gesture fires |

### Microphone / TDOA (new — MicInputService)
| Location | Symbol | Default | Purpose |
|---|---|---|---|
| `Models.swift` `AppSettings` | `micEnabled` | `false` | Enable acoustic tap detection |
| `MicInputService.swift` | `MIC_SAMPLE_RATE` | `48000` | AVAudioEngine capture rate (Hz) |
| `MicInputService.swift` | `HIGHPASS_CUTOFF_HZ` | `150.0` | High-pass filter cutoff; removes rumble, preserves tap transient |
| `MicInputService.swift` | `HIGHPASS_ORDER` | `4` | Butterworth filter order (higher = steeper rolloff) |
| `MicInputService.swift` | `NOISE_WINDOW_FRAMES` | `200` | Frames used to compute rolling RMS noise floor |
| `Models.swift` `AppSettings` | `micThresholdMultiplier` | `6.0` | Peak must exceed `noiseFloor × multiplier` to register |
| `Models.swift` `AppSettings` | `micSideThresholdMs` | `0.2` | Max TDOA (ms) to classify as center; beyond → left or right |

### Gesture side dimension (new)
`GestureType` gains a `side: TapSide` property — `.left`, `.center`, `.right`. The existing `.single/.double/.triple` count axis is unchanged. Bindings are now keyed on `(count, side)`, giving up to 9 bindable gestures. When `micEnabled` is false the side defaults to `.center` for backwards compatibility.
