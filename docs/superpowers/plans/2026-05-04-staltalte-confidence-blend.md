# STA/LTA Confidence Blend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a calibration-free STA/LTA energy ratio score that runs in parallel with the existing ML scorer so soft taps pass the gate even before a calibration model exists.

**Architecture:** At tracking-window close, compute the ratio of peak-energy (15 ms STA) to background-energy (500 ms LTA) from the differentiated samples already in `IMUCircularBuffer`. Store the result in `TapEvent.staLtaScore`. In `AppEnvironment`, blend it with the ML score via `max(mlScore, staLtaScore)` before the gate check. The rest of the pipeline (noise model, gesture classifier, calibration) is untouched.

**Tech Stack:** Swift 5.9, SwiftUI, no external dependencies, no test suite (use `swift build` for correctness verification).

---

## File Map

| File | Change |
|------|--------|
| `Sources/TapTap/TapEvent.swift` | Add `staLtaScore: Double` field |
| `Sources/TapTap/Models.swift` | Add `staLtaEnabled: Bool = true` to `AppSettings` (stored + backward-compat decoder) |
| `Sources/TapTap/Services/TapInputService.swift` | Compute `staLtaScore` in `closeTrackingWindow()` |
| `Sources/TapTap/AppEnvironment.swift` | Blend STA/LTA into ML gate; update two debug log lines |
| `Sources/TapTap/Views/DetectionView.swift` | Add toggle for `staLtaEnabled` in "ML Filter" section |

---

## Task 1: Add `staLtaScore` field to `TapEvent`

**Files:**
- Modify: `Sources/TapTap/TapEvent.swift`

- [ ] **Step 1: Add the field**

Open `Sources/TapTap/TapEvent.swift`. After line 31 (`var features: TapFeatureVector?`), add:

```swift
    /// STA/LTA energy ratio score (0–1). 0 when STA/LTA is disabled or buffer not yet warmed up.
    var staLtaScore: Double = 0.0
```

The full struct now reads:
```swift
struct TapEvent: Codable, Sendable {
    let timestamp: Date
    let peakMagnitude: Double
    let peakX: Double
    let peakY: Double
    let peakZ: Double
    let closingGyroMagnitude: Double
    let crestFactor: Double
    let riseTimeMs: Double
    var features: TapFeatureVector?
    var staLtaScore: Double = 0.0

    var axisRatioZ: Double { abs(peakZ) / max(peakMagnitude, 1e-6) }
}
```

`staLtaScore` is `var` with a default of `0.0` so existing synthesised memberwise initialisers in `TapInputService` continue to compile without being modified yet (the field will be set explicitly in Task 3).

- [ ] **Step 2: Build to verify**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/TapTap/TapEvent.swift
git commit -m "feat: add staLtaScore field to TapEvent"
```

---

## Task 2: Add `staLtaEnabled` to `AppSettings`

**Files:**
- Modify: `Sources/TapTap/Models.swift`

- [ ] **Step 1: Add the stored property**

In `Sources/TapTap/Models.swift`, find the `struct AppSettings` block. After the line:

```swift
    var userOverrodeMLThreshold: Bool = false
```

Add:

```swift
    var staLtaEnabled: Bool = true
```

- [ ] **Step 2: Add to `CodingKeys`**

In the same struct, find the `enum CodingKeys` block. After:

```swift
        case sensitivityBias, noiseModelEnabled, userOverrodeMLThreshold
```

Add:

```swift
        case staLtaEnabled
```

- [ ] **Step 3: Add to the backward-compatible decoder**

In `init(from decoder: Decoder)`, after the line:

```swift
        userOverrodeMLThreshold   = (try? c.decode(Bool.self,   forKey: .userOverrodeMLThreshold))   ?? false
```

Add:

```swift
        staLtaEnabled             = (try? c.decode(Bool.self,   forKey: .staLtaEnabled))             ?? true
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/TapTap/Models.swift
git commit -m "feat: add staLtaEnabled setting to AppSettings"
```

---

## Task 3: Compute STA/LTA in `TapInputService.closeTrackingWindow()`

**Files:**
- Modify: `Sources/TapTap/Services/TapInputService.swift`

- [ ] **Step 1: Add the computation block**

In `Sources/TapTap/Services/TapInputService.swift`, find `closeTrackingWindow()`. Locate the section that constructs `TapEvent` — it starts around line 276:

```swift
        let event = TapEvent(
            timestamp:            trackingStart,
            peakMagnitude:        trackingPeakMag,
```

Immediately **before** that `let event = TapEvent(` line, insert:

```swift
        // STA/LTA energy ratio — detects soft taps independently of calibration.
        // STA: 3 samples (~15 ms) centred on peak.
        // LTA: 100 samples (~500 ms) ending 2 samples before peak (no contamination).
        let staLtaScore: Double = {
            let sr        = Self.sampleRate
            let staCount  = max(1, Int(0.015 * sr))   // 3 samples
            let ltaCount  = Int(0.500 * sr)            // 100 samples
            let staSamples = imuBuf.slice(from: trackingPeakBufIdx - staCount / 2, count: staCount)
            let ltaSamples = imuBuf.slice(from: trackingPeakBufIdx - ltaCount - 2, count: ltaCount)
            guard !staSamples.isEmpty, ltaSamples.count >= ltaCount / 2 else { return 0.0 }
            let staMean = staSamples.map { $0.dax*$0.dax + $0.day*$0.day + $0.daz*$0.daz }.reduce(0, +) / Double(staSamples.count)
            let ltaMean = ltaSamples.map { $0.dax*$0.dax + $0.day*$0.day + $0.daz*$0.daz }.reduce(0, +) / Double(ltaSamples.count)
            guard ltaMean > 1e-12 else { return 0.0 }
            return min(1.0, max(0.0, (staMean / ltaMean - 1.0) / 9.0))
        }()
```

- [ ] **Step 2: Pass the score into the TapEvent initialiser**

The `TapEvent` struct has `var staLtaScore: Double = 0.0` with a default, so the existing memberwise init still compiles. To actually populate it, change:

```swift
        let event = TapEvent(
            timestamp:            trackingStart,
            peakMagnitude:        trackingPeakMag,
            peakX:                trackingPeakX,
            peakY:                trackingPeakY,
            peakZ:                trackingPeakZ,
            closingGyroMagnitude: closingGyro,
            crestFactor:          crestFactor,
            riseTimeMs:           riseTimeMs,
            features:             tapFeatures
        )
```

To:

```swift
        var event = TapEvent(
            timestamp:            trackingStart,
            peakMagnitude:        trackingPeakMag,
            peakX:                trackingPeakX,
            peakY:                trackingPeakY,
            peakZ:                trackingPeakZ,
            closingGyroMagnitude: closingGyro,
            crestFactor:          crestFactor,
            riseTimeMs:           riseTimeMs,
            features:             tapFeatures
        )
        event.staLtaScore = staLtaScore
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/TapTap/Services/TapInputService.swift
git commit -m "feat: compute STA/LTA energy ratio score in closeTrackingWindow"
```

---

## Task 4: Blend STA/LTA into the ML gate in `AppEnvironment`

**Files:**
- Modify: `Sources/TapTap/AppEnvironment.swift`

- [ ] **Step 1: Replace the ML gate block**

In `Sources/TapTap/AppEnvironment.swift`, find the ML gate block (around line 199). Replace:

```swift
            // ML gate
            if self.store.settings.mlEnabled,
               self.calibration.isMLReady,
               let data = self.calibration.calibrationData {

                let tapScore = data.matchScore(for: event)

                // Apply likelihood ratio when noise model is active
                let finalScore: Double
                let s = self.store.settings
                if s.noiseModelEnabled, self.noiseModel.isActive,
                   let fv = event.features?.toArray() {
                    let noiseScore = self.noiseModel.score(for: fv)
                    finalScore = self.noiseModel.finalScore(tapScore: tapScore, noiseScore: noiseScore)
                } else {
                    finalScore = tapScore
                }
                self.lastTapScore = finalScore

                let threshold = self.effectiveMLThreshold(for: data)
                guard finalScore >= threshold else {
                    // Feed noise model: only strongly-rejected events (raw tapScore < 0.10)
                    if self.store.settings.noiseModelEnabled,
                       tapScore < 0.10,
                       let fv = event.features?.toArray() {
                        self.noiseModel.update(features: fv)
                        self.persistNoiseModel()
                    }
                    if self.store.settings.debugLoggingEnabled {
                        self.logger.log(
                            String(format: "ML filtered tap %.2fg (tap %.2f, final %.2f, threshold %.2f)",
                                   event.peakMagnitude, tapScore, finalScore, threshold),
                            kind: .system
                        )
                    }
                    return
                }
            } else {
                self.lastTapScore = nil
            }
```

With:

```swift
            // ML gate
            if self.store.settings.mlEnabled,
               self.calibration.isMLReady,
               let data = self.calibration.calibrationData {

                let s        = self.store.settings
                let mlScore  = data.matchScore(for: event)
                let staScore = s.staLtaEnabled ? event.staLtaScore : 0.0
                let blended  = max(mlScore, staScore)

                // Apply likelihood ratio when noise model is active
                let finalScore: Double
                if s.noiseModelEnabled, self.noiseModel.isActive,
                   let fv = event.features?.toArray() {
                    let noiseScore = self.noiseModel.score(for: fv)
                    finalScore = self.noiseModel.finalScore(tapScore: blended, noiseScore: noiseScore)
                } else {
                    finalScore = blended
                }
                self.lastTapScore = finalScore

                let threshold = self.effectiveMLThreshold(for: data)
                guard finalScore >= threshold else {
                    // Feed noise model only from events the ML scorer rejects strongly.
                    // Events that pass via STA/LTA but have low mlScore are real taps — skip.
                    if s.noiseModelEnabled,
                       mlScore < 0.10,
                       let fv = event.features?.toArray() {
                        self.noiseModel.update(features: fv)
                        self.persistNoiseModel()
                    }
                    if s.debugLoggingEnabled {
                        self.logger.log(
                            String(format: "ML filtered: %.2fg (ml=%.2f, sta=%.2f, final=%.2f, thresh=%.2f)",
                                   event.peakMagnitude, mlScore, event.staLtaScore, finalScore, threshold),
                            kind: .system
                        )
                    }
                    return
                }
            } else {
                self.lastTapScore = nil
            }
```

- [ ] **Step 2: Update the raw-tap debug log line**

Find (around line 177):

```swift
            if self.store.settings.debugLoggingEnabled {
                self.logger.log(
                    String(format: "Raw tap: %.3fg", event.peakMagnitude),
                    kind: .system
                )
            }
```

Replace with:

```swift
            if self.store.settings.debugLoggingEnabled {
                self.logger.log(
                    String(format: "Raw tap: %.3fg  sta=%.2f", event.peakMagnitude, event.staLtaScore),
                    kind: .system
                )
            }
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/TapTap/AppEnvironment.swift
git commit -m "feat: blend STA/LTA score into ML gate to pass soft taps"
```

---

## Task 5: Add STA/LTA toggle to `DetectionView`

**Files:**
- Modify: `Sources/TapTap/Views/DetectionView.swift`

- [ ] **Step 1: Add toggle in the ML Filter section**

In `Sources/TapTap/Views/DetectionView.swift`, find the `Section("ML Filter")` block (around line 157). It currently reads:

```swift
            Section("ML Filter") {
                Toggle("ML filter", isOn: Binding(
                    get: { env.store.settings.mlEnabled },
                    set: { v in mutateSettings { $0.mlEnabled = v } }
                ))
                if env.store.settings.mlEnabled {
```

Add the STA/LTA toggle and its caption immediately after the ML filter toggle, before the `if env.store.settings.mlEnabled {` block:

```swift
            Section("ML Filter") {
                Toggle("ML filter", isOn: Binding(
                    get: { env.store.settings.mlEnabled },
                    set: { v in mutateSettings { $0.mlEnabled = v } }
                ))
                Toggle("STA/LTA energy gate", isOn: Binding(
                    get: { env.store.settings.staLtaEnabled },
                    set: { v in mutateSettings { $0.staLtaEnabled = v } }
                ))
                Text("Detects taps by energy spike relative to background noise. Lets soft taps through even before calibration. Disable only if you see false positives from desk vibration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if env.store.settings.mlEnabled {
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 3: Build the app bundle and smoke-test**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && bash build-app.sh && open TapTap.app
```

Verify:
1. App launches and shows menu bar icon.
2. Open Detection tab → "ML Filter" section shows "STA/LTA energy gate" toggle, defaulting to on.
3. Enable debug logging → tap the laptop softly → Debug Log shows `Raw tap: Xg  sta=0.XX` with a non-zero `sta` value (typically 0.3–0.8 for a real tap).
4. A soft tap that was previously filtered should now appear as "Detected" in the log instead of "ML filtered".

- [ ] **Step 4: Commit**

```bash
git add Sources/TapTap/Views/DetectionView.swift
git commit -m "feat: add STA/LTA energy gate toggle to DetectionView"
```
