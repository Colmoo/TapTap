# Tap Detection Precision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 3-feature Gaussian ML scorer with a 17-feature model, add a passive noise model that learns from rejected events, and consolidate all filter controls into a single Sensitivity slider plus a noise model toggle.

**Architecture:** `CalibrationData` gains a full 17-feature mean/std array and an auto-derived floor threshold. A new `NoiseModel` struct accumulates rejected events passively via EMA and enables likelihood-ratio scoring once 30 samples are collected. `AppEnvironment` wires both models together and computes an effective threshold from calibration floor + sensitivity bias.

**Tech Stack:** Swift, SwiftUI, Foundation (UserDefaults for persistence). No test framework — build verification and manual UI testing via the debug log.

---

## File Map

| File | Role |
|---|---|
| `Sources/TapTap/TapEvent.swift` | Expand `CalibrationData`; add `NoiseModel` |
| `Sources/TapTap/Models.swift` | Add 3 new `AppSettings` fields |
| `Sources/TapTap/AppEnvironment.swift` | Wire likelihood ratio, noise accumulation, effective threshold |
| `Sources/TapTap/Views/DetectionView.swift` | Sensitivity slider, noise model section, Advanced group |

`CalibrationManager.swift` needs one small addition (reset override flag on calibration complete) — handled inside Task 3.

---

## Task 1: Expand CalibrationData with 17-feature model

**Files:**
- Modify: `Sources/TapTap/TapEvent.swift`

### Goal
Add `featureMean`, `featureStd`, and `calibrationFloorScore` to `CalibrationData`. Update `fit`, `matchScore`, `updating`, and `bootstrap` to use the full `TapFeatureVector` (17 scalars from `TapFeatureVector.toArray()`). Add a custom `init(from:)` so existing UserDefaults data (without these keys) still loads correctly.

- [ ] **Step 1: Add new fields and custom decoder to CalibrationData**

Open `Sources/TapTap/TapEvent.swift`. Replace the `CalibrationData` struct definition (lines 55–174) with the version below. The only structural changes are: three new `var` fields, a custom `init(from:)` with `decodeIfPresent` for those fields, and a private `legacyMatchScore` that preserves the old behaviour as a fallback.

```swift
struct CalibrationData: Codable, Sendable {
    let calibratedAt: Date
    let sampleCount: Int

    // Gaussian fit — kept for legacy fallback and quality grading
    let meanCrestFactor: Double
    let stdCrestFactor: Double
    let meanRiseTime: Double
    let stdRiseTime: Double
    let meanAxisZ: Double
    let stdAxisZ: Double

    // Full 17-feature model (TapFeatureVector.toArray())
    var featureMean: [Double]           // empty when model was fit without feature vectors
    var featureStd:  [Double]
    var calibrationFloorScore: Double   // lowest matchScore among calibration samples

    var learnedDoubleTapWindowMs: Double?
    var learnedTripleTapWindowMs: Double?

    // MARK: - Backward-compatible decoder

    enum CodingKeys: String, CodingKey {
        case calibratedAt, sampleCount
        case meanCrestFactor, stdCrestFactor
        case meanRiseTime, stdRiseTime
        case meanAxisZ, stdAxisZ
        case featureMean, featureStd, calibrationFloorScore
        case learnedDoubleTapWindowMs, learnedTripleTapWindowMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calibratedAt       = try c.decode(Date.self,   forKey: .calibratedAt)
        sampleCount        = try c.decode(Int.self,    forKey: .sampleCount)
        meanCrestFactor    = try c.decode(Double.self, forKey: .meanCrestFactor)
        stdCrestFactor     = try c.decode(Double.self, forKey: .stdCrestFactor)
        meanRiseTime       = try c.decode(Double.self, forKey: .meanRiseTime)
        stdRiseTime        = try c.decode(Double.self, forKey: .stdRiseTime)
        meanAxisZ          = try c.decode(Double.self, forKey: .meanAxisZ)
        stdAxisZ           = try c.decode(Double.self, forKey: .stdAxisZ)
        learnedDoubleTapWindowMs = try c.decodeIfPresent(Double.self, forKey: .learnedDoubleTapWindowMs)
        learnedTripleTapWindowMs = try c.decodeIfPresent(Double.self, forKey: .learnedTripleTapWindowMs)
        featureMean            = (try? c.decode([Double].self, forKey: .featureMean))  ?? []
        featureStd             = (try? c.decode([Double].self, forKey: .featureStd))   ?? []
        calibrationFloorScore  = (try? c.decode(Double.self,  forKey: .calibrationFloorScore)) ?? 0.0
    }

    // Memberwise init used by fit/updating/bootstrap
    init(calibratedAt: Date, sampleCount: Int,
         meanCrestFactor: Double, stdCrestFactor: Double,
         meanRiseTime: Double, stdRiseTime: Double,
         meanAxisZ: Double, stdAxisZ: Double,
         featureMean: [Double], featureStd: [Double],
         calibrationFloorScore: Double,
         learnedDoubleTapWindowMs: Double?, learnedTripleTapWindowMs: Double?) {
        self.calibratedAt              = calibratedAt
        self.sampleCount               = sampleCount
        self.meanCrestFactor           = meanCrestFactor
        self.stdCrestFactor            = stdCrestFactor
        self.meanRiseTime              = meanRiseTime
        self.stdRiseTime               = stdRiseTime
        self.meanAxisZ                 = meanAxisZ
        self.stdAxisZ                  = stdAxisZ
        self.featureMean               = featureMean
        self.featureStd                = featureStd
        self.calibrationFloorScore     = calibrationFloorScore
        self.learnedDoubleTapWindowMs  = learnedDoubleTapWindowMs
        self.learnedTripleTapWindowMs  = learnedTripleTapWindowMs
    }

    // MARK: - Scoring

    func matchScore(for event: TapEvent) -> Double {
        if let fv = event.features?.toArray(),
           fv.count == featureMean.count, !featureMean.isEmpty {
            return fullFeatureScore(fv)
        }
        return legacyMatchScore(for: event)
    }

    private func fullFeatureScore(_ fv: [Double]) -> Double {
        var zSum = 0.0; var count = 0
        for i in 0..<fv.count {
            guard featureStd[i] > 1e-6 else { continue }
            zSum += abs((fv[i] - featureMean[i]) / featureStd[i])
            count += 1
        }
        guard count > 0 else { return 0.5 }  // all stds collapsed — neutral score
        return max(0, 1.0 - (zSum / Double(count)) / 3.0)
    }

    private func legacyMatchScore(for event: TapEvent) -> Double {
        let zCrest = stdCrestFactor > 1e-6 ? (event.crestFactor - meanCrestFactor) / stdCrestFactor : 0
        let zRise  = stdRiseTime  > 1e-6 ? (event.riseTimeMs  - meanRiseTime)  / stdRiseTime  : 0
        return max(0, 1.0 - (abs(zCrest) + abs(zRise)) / 2.0 / 3.0)
    }

    /// Letter grade reflecting tap shape consistency.
    var qualityGrade: String {
        let cv = stdCrestFactor / max(meanCrestFactor, 1e-6)
        switch cv {
        case ..<0.10: return "A"
        case ..<0.20: return "B"
        case ..<0.35: return "C"
        default:      return "D"
        }
    }

    // MARK: - Factory

    static func fit(
        samples: [TapEvent],
        learnedDoubleTapWindowMs: Double? = nil,
        learnedTripleTapWindowMs: Double? = nil
    ) -> CalibrationData {
        precondition(!samples.isEmpty)
        let crests = samples.map(\.crestFactor)
        let rises  = samples.map(\.riseTimeMs)
        let axisZs = samples.map(\.axisRatioZ)

        // Build 17-feature arrays from samples that have a TapFeatureVector
        let fvArrays = samples.compactMap { $0.features?.toArray() }
        let dim = fvArrays.first?.count ?? 0
        var fMean = [Double](repeating: 0, count: dim)
        var fStd  = [Double](repeating: 0, count: dim)
        if !fvArrays.isEmpty {
            let n = Double(fvArrays.count)
            for i in 0..<dim {
                fMean[i] = fvArrays.map { $0[i] }.reduce(0, +) / n
                let variance = fvArrays.map { pow($0[i] - fMean[i], 2) }.reduce(0, +) / n
                fStd[i] = sqrt(variance)
            }
        }

        var data = CalibrationData(
            calibratedAt: Date(), sampleCount: samples.count,
            meanCrestFactor: crests.statisticalMean, stdCrestFactor: crests.standardDeviation,
            meanRiseTime: rises.statisticalMean,     stdRiseTime: rises.standardDeviation,
            meanAxisZ: axisZs.statisticalMean,       stdAxisZ: axisZs.standardDeviation,
            featureMean: fMean, featureStd: fStd,
            calibrationFloorScore: 0,
            learnedDoubleTapWindowMs: learnedDoubleTapWindowMs,
            learnedTripleTapWindowMs: learnedTripleTapWindowMs
        )
        data.calibrationFloorScore = samples.map { data.matchScore(for: $0) }.min() ?? 1.0
        return data
    }

    static func bootstrap(from event: TapEvent) -> CalibrationData {
        let fv    = event.features?.toArray() ?? []
        let prior = fv.map { _ in 1.0 }
        return CalibrationData(
            calibratedAt: Date(), sampleCount: 1,
            meanCrestFactor: event.crestFactor, stdCrestFactor: 0.5,
            meanRiseTime: event.riseTimeMs,     stdRiseTime: 10.0,
            meanAxisZ: event.axisRatioZ,        stdAxisZ: 0.20,
            featureMean: fv, featureStd: prior,
            calibrationFloorScore: 0.0,
            learnedDoubleTapWindowMs: nil, learnedTripleTapWindowMs: nil
        )
    }

    func updating(with event: TapEvent) -> CalibrationData {
        let α: Double = 0.05

        let c = event.crestFactor
        let oldMC = meanCrestFactor
        let newMC = oldMC + α * (c - oldMC)
        let newVC = (1 - α) * (stdCrestFactor * stdCrestFactor + α * pow(c - oldMC, 2))

        let r = event.riseTimeMs
        let oldMR = meanRiseTime
        let newMR = oldMR + α * (r - oldMR)
        let newVR = (1 - α) * (stdRiseTime * stdRiseTime + α * pow(r - oldMR, 2))

        let z = event.axisRatioZ
        let oldMZ = meanAxisZ
        let newMZ = oldMZ + α * (z - oldMZ)
        let newVZ = (1 - α) * (stdAxisZ * stdAxisZ + α * pow(z - oldMZ, 2))

        var newFMean = featureMean
        var newFStd  = featureStd
        if let fv = event.features?.toArray(), fv.count == featureMean.count, !featureMean.isEmpty {
            for i in 0..<fv.count {
                let old   = newFMean[i]
                newFMean[i] = old + α * (fv[i] - old)
                let oldV    = newFStd[i] * newFStd[i]
                newFStd[i]  = sqrt(max(1e-6, (1 - α) * (oldV + α * pow(fv[i] - old, 2))))
            }
        }

        return CalibrationData(
            calibratedAt: calibratedAt, sampleCount: sampleCount + 1,
            meanCrestFactor: newMC, stdCrestFactor: sqrt(max(1e-6, newVC)),
            meanRiseTime: newMR,    stdRiseTime:    sqrt(max(1e-6, newVR)),
            meanAxisZ: newMZ,       stdAxisZ:       sqrt(max(1e-6, newVZ)),
            featureMean: newFMean,  featureStd: newFStd,
            calibrationFloorScore: calibrationFloorScore,
            learnedDoubleTapWindowMs: learnedDoubleTapWindowMs,
            learnedTripleTapWindowMs: learnedTripleTapWindowMs
        )
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!` (or only pre-existing warnings — no new errors).

- [ ] **Step 3: Commit**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
git add Sources/TapTap/TapEvent.swift
git commit -m "feat: expand CalibrationData to 17-feature Mahalanobis scorer with auto floor threshold"
```

---

## Task 2: Add NoiseModel struct

**Files:**
- Modify: `Sources/TapTap/TapEvent.swift` (append after CalibrationData)

### Goal
Define `NoiseModel` — a rolling EMA model over the same 17-feature space, built passively from strongly-rejected events.

- [ ] **Step 1: Append NoiseModel to TapEvent.swift**

Add the following after the closing `}` of `CalibrationData` (before the `// MARK: - Array statistics helpers` section):

```swift
// MARK: - Noise model

/// Passive EMA model fitted from strongly-rejected IMU events (score < 0.10).
/// Activates for scoring once sampleCount ≥ 30; before that it accumulates silently.
struct NoiseModel: Codable, Sendable {
    var updatedAt: Date
    var sampleCount: Int
    var featureMean: [Double]   // 17 elements — same space as CalibrationData
    var featureStd:  [Double]

    static let activationThreshold = 30
    static let persistenceKey = "TapTap.noiseModel.v1"

    static var empty: NoiseModel {
        NoiseModel(updatedAt: Date(), sampleCount: 0, featureMean: [], featureStd: [])
    }

    var isActive: Bool { sampleCount >= Self.activationThreshold }

    /// EMA update with α = 0.05. First call seeds the mean; subsequent calls refine it.
    mutating func update(features: [Double]) {
        let α: Double = 0.05
        if featureMean.isEmpty {
            featureMean = features
            featureStd  = features.map { _ in 1.0 }
        } else if features.count == featureMean.count {
            for i in 0..<features.count {
                let old      = featureMean[i]
                featureMean[i] = old + α * (features[i] - old)
                let oldV     = featureStd[i] * featureStd[i]
                featureStd[i]  = sqrt(max(1e-6, (1 - α) * (oldV + α * pow(features[i] - old, 2))))
            }
        }
        sampleCount += 1
        updatedAt = Date()
    }

    /// Diagonal Mahalanobis score in [0, 1]. 1.0 = looks exactly like noise centroid.
    func score(for features: [Double]) -> Double {
        guard features.count == featureMean.count, !featureMean.isEmpty else { return 0 }
        var zSum = 0.0; var count = 0
        for i in 0..<features.count {
            guard featureStd[i] > 1e-6 else { continue }
            zSum += abs((features[i] - featureMean[i]) / featureStd[i])
            count += 1
        }
        guard count > 0 else { return 0 }
        return max(0, 1.0 - (zSum / Double(count)) / 3.0)
    }

    /// Likelihood-ratio score. rampWeight goes 0→1 as sampleCount grows from 30→100.
    /// Returns tapScore unchanged when the noise model is not yet active.
    func finalScore(tapScore: Double, noiseScore: Double) -> Double {
        guard isActive else { return tapScore }
        let ramp = min(1.0, Double(sampleCount - Self.activationThreshold) / 70.0)
        return tapScore / (tapScore + noiseScore * ramp + 1e-9)
    }
}
```

- [ ] **Step 2: Build**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TapTap/TapEvent.swift
git commit -m "feat: add passive NoiseModel with EMA update and likelihood-ratio scoring"
```

---

## Task 3: Add new AppSettings fields + reset flag on calibration complete

**Files:**
- Modify: `Sources/TapTap/Models.swift`
- Modify: `Sources/TapTap/Services/CalibrationManager.swift`

### Goal
Add `sensitivityBias`, `noiseModelEnabled`, and `userOverrodeMLThreshold` to `AppSettings` with a backward-compatible custom decoder. Reset `userOverrodeMLThreshold` when calibration completes.

- [ ] **Step 1: Add new fields and custom decoder to AppSettings**

In `Sources/TapTap/Models.swift`, find the `struct AppSettings: Codable, Sendable {` block. Replace the entire struct with the version below. All existing fields are preserved; only the three new fields and the custom `init(from:)` are added.

```swift
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
    var micSideThresholdMs: Double = 0.2
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

    // MARK: Backward-compatible decoder

    enum CodingKeys: String, CodingKey {
        case doubleTapWindowMs, tripleTapWindowMs, globalCooldownMs
        case tapThresholdG, tapPeakCooldownMs, launchAtLogin, debugLoggingEnabled
        case mlEnabled, mlScoreThreshold, movementGyroThresholdRadS
        case micEnabled, micThresholdMultiplier, micSideThresholdMs
        case micConfirmationEnabled, micCorrelationWindowSec, micUnconfirmedPenalty
        case gyroEnergyGateThreshold, peakValleyCheckEnabled, imuSideEnabled
        case sensitivityBias, noiseModelEnabled, userOverrodeMLThreshold
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
        micSideThresholdMs        = (try? c.decode(Double.self, forKey: .micSideThresholdMs))        ?? 0.2
        micConfirmationEnabled    = (try? c.decode(Bool.self,   forKey: .micConfirmationEnabled))    ?? false
        micCorrelationWindowSec   = (try? c.decode(Double.self, forKey: .micCorrelationWindowSec))   ?? 0.030
        micUnconfirmedPenalty     = (try? c.decode(Double.self, forKey: .micUnconfirmedPenalty))     ?? 0.5
        gyroEnergyGateThreshold   = (try? c.decode(Double.self, forKey: .gyroEnergyGateThreshold))  ?? 0.0
        peakValleyCheckEnabled    = (try? c.decode(Bool.self,   forKey: .peakValleyCheckEnabled))    ?? false
        imuSideEnabled            = (try? c.decode(Bool.self,   forKey: .imuSideEnabled))            ?? false
        sensitivityBias           = (try? c.decode(Double.self, forKey: .sensitivityBias))           ?? 0.0
        noiseModelEnabled         = (try? c.decode(Bool.self,   forKey: .noiseModelEnabled))         ?? false
        userOverrodeMLThreshold   = (try? c.decode(Bool.self,   forKey: .userOverrodeMLThreshold))   ?? false
    }
}
```

- [ ] **Step 2: Reset userOverrodeMLThreshold when calibration completes**

In `Sources/TapTap/AppEnvironment.swift`, find the `calibration.onCalibrationComplete` closure (around line 126). It contains `var s = self.store.settings` followed by the two timing-window `if let` blocks. Add one line immediately before `self.store.update(settings: s)`:

```swift
s.userOverrodeMLThreshold = false   // re-enable auto-threshold after recalibration
```

Do not change any other lines in the closure.

- [ ] **Step 3: Build**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/TapTap/Models.swift Sources/TapTap/AppEnvironment.swift
git commit -m "feat: add sensitivityBias, noiseModelEnabled, userOverrodeMLThreshold to AppSettings"
```

---

## Task 4: Wire AppEnvironment — noise model + effective threshold

**Files:**
- Modify: `Sources/TapTap/AppEnvironment.swift`

### Goal
Load/persist `NoiseModel`, compute the effective ML threshold from calibration floor + sensitivity bias, apply the likelihood ratio, and feed rejected events into the noise model.

- [ ] **Step 1: Add noiseModel state and persistence helpers to AppEnvironment**

In `Sources/TapTap/AppEnvironment.swift`, add the following after the `private var lastMovementTime` line (around line 23):

```swift
/// Passive noise model — populated from strongly-rejected IMU events.
private(set) var noiseModel: NoiseModel = .empty
```

Then add these three private methods anywhere inside the `AppEnvironment` class body (e.g. after `toggleListening()`):

```swift
// MARK: - Noise model persistence

private func loadNoiseModel() {
    guard let raw  = UserDefaults.standard.data(forKey: NoiseModel.persistenceKey),
          let model = try? JSONDecoder().decode(NoiseModel.self, from: raw) else { return }
    noiseModel = model
}

private func persistNoiseModel() {
    guard let data = try? JSONEncoder().encode(noiseModel) else { return }
    UserDefaults.standard.set(data, forKey: NoiseModel.persistenceKey)
}

func resetNoiseModel() {
    noiseModel = .empty
    UserDefaults.standard.removeObject(forKey: NoiseModel.persistenceKey)
}
```

Also call `loadNoiseModel()` inside `init()`, right after `wireUpPipeline()`:

```swift
init() {
    applySettings()
    wireUpPipeline()
    loadNoiseModel()    // ← new
    startListening()
}
```

- [ ] **Step 2: Add effectiveMLThreshold helper**

Add this private method after `applySettings()`:

```swift
/// Returns the ML gate threshold to compare final scores against.
/// Uses calibration floor × 0.85 + sensitivity bias unless the user manually overrode it.
private func effectiveMLThreshold(for data: CalibrationData) -> Double {
    let s = store.settings
    if s.userOverrodeMLThreshold { return s.mlScoreThreshold }
    let auto = data.calibrationFloorScore * 0.85
    return min(0.99, max(0.01, auto + s.sensitivityBias * 0.15))
}
```

- [ ] **Step 3: Replace the ML gate block in wireUpPipeline**

In `wireUpPipeline()`, find the ML gate block (starting at `if self.store.settings.mlEnabled`). Replace it entirely with the version below. The only changes are: `effectiveMLThreshold` replaces `mlScoreThreshold`, likelihood ratio is applied, and rejected events feed the noise model.

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

- [ ] **Step 4: Build**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Smoke-test via debug log**

```bash
bash "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap/build-app.sh"
open "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap/TapTap.app"
```

Open the app, go to Detection → enable ML filter, tap the palm rest a few times. Open the Debug Log tab and verify log lines now show three values: `tap X.XX, final X.XX, threshold X.XX`. The noise model section won't appear in the UI until Task 5.

- [ ] **Step 6: Commit**

```bash
git add Sources/TapTap/AppEnvironment.swift
git commit -m "feat: wire likelihood ratio, noise accumulation, and auto-threshold into AppEnvironment"
```

---

## Task 5: Update DetectionView — Sensitivity slider, noise model section, Advanced group

**Files:**
- Modify: `Sources/TapTap/Views/DetectionView.swift`

### Goal
Replace the `mlScoreThreshold` slider with a Sensitivity slider. Add a Noise model section (toggle, status line, Reset button). Move gyro energy gate, rebound check, and the raw threshold slider into an Advanced disclosure group.

- [ ] **Step 1: Replace the Signal Processing and Sensitivity sections**

In `Sources/TapTap/Views/DetectionView.swift`, find the `Section("Signal Processing")` block and the `Section("Sensitivity")` block. Replace both sections with the following four sections:

```swift
Section("ML Filter") {
    Toggle("ML filter", isOn: Binding(
        get: { env.store.settings.mlEnabled },
        set: { v in mutateSettings { $0.mlEnabled = v } }
    ))
    if env.store.settings.mlEnabled {
        SliderRow(
            label: "Sensitivity",
            value: Binding(
                get: { env.store.settings.sensitivityBias },
                set: { v in mutateSettings { $0.sensitivityBias = v } }
            ),
            range: -1.0...1.0,
            format: "%.2f"
        )
        Text("Low (−1) catches lighter taps with more false positives. High (+1) is stricter. Auto-set from your calibration profile.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

Section("Noise Model") {
    Toggle("Learn from noise", isOn: Binding(
        get: { env.store.settings.noiseModelEnabled },
        set: { v in mutateSettings { $0.noiseModelEnabled = v } }
    ))
    Text("Passively builds a profile of typing, desk bumps, and trackpad clicks from rejected events. No extra calibration needed.")
        .font(.caption)
        .foregroundStyle(.secondary)

    LabeledContent("Status") {
        Text(noiseModelStatus)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    if env.noiseModel.sampleCount > 0 {
        Button("Reset noise model", role: .destructive) {
            env.resetNoiseModel()
        }
    }
}

Section("Sensitivity") {
    SliderRow(
        label: "Tap threshold",
        value: Binding(
            get: { env.store.settings.tapThresholdG },
            set: { v in mutateSettings { $0.tapThresholdG = v } }
        ),
        range: 1.02...1.5,
        format: "%.2f g"
    )
    Text("Acceleration magnitude that counts as a tap. Lower = more sensitive. At rest ~1 g; a gentle knock peaks at 1.05–1.1 g.")
        .font(.caption)
        .foregroundStyle(.secondary)

    SliderRow(
        label: "Movement rejection",
        value: Binding(
            get: { env.store.settings.movementGyroThresholdRadS },
            set: { v in mutateSettings { $0.movementGyroThresholdRadS = v } }
        ),
        range: 0.1...3.0,
        format: "%.1f rad/s"
    )
    Text("Gyroscope threshold for rejecting whole-laptop movement. Set to max to disable.")
        .font(.caption)
        .foregroundStyle(.secondary)

    SliderRow(
        label: "Peak cooldown",
        value: Binding(
            get: { env.store.settings.tapPeakCooldownMs },
            set: { v in mutateSettings { $0.tapPeakCooldownMs = v } }
        ),
        range: 20...200,
        format: "%.0f ms"
    )
    Text("Minimum time between tap events. Prevents vibration echo.")
        .font(.caption)
        .foregroundStyle(.secondary)
}

DisclosureGroup("Advanced") {
    Section {
        Toggle("Rebound check", isOn: Binding(
            get: { env.store.settings.peakValleyCheckEnabled },
            set: { v in mutateSettings { $0.peakValleyCheckEnabled = v } }
        ))
        Text("Requires a z-axis bounce-back within 30 ms of peak. Filters slow desk bumps.")
            .font(.caption)
            .foregroundStyle(.secondary)

        SliderRow(
            label: "Gyro energy gate",
            value: Binding(
                get: { env.store.settings.gyroEnergyGateThreshold },
                set: { v in mutateSettings { $0.gyroEnergyGateThreshold = v } }
            ),
            range: 0.0...0.5,
            format: "%.3f"
        )
        Text("Minimum rotation energy during the tap window. Set to 0 to disable.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if env.store.settings.mlEnabled {
            SliderRow(
                label: "Raw ML threshold",
                value: Binding(
                    get: { env.store.settings.mlScoreThreshold },
                    set: { v in mutateSettings { $0.mlScoreThreshold = v; $0.userOverrodeMLThreshold = true } }
                ),
                range: 0.0...1.0,
                format: "%.2f"
            )
            Text("Overrides the auto-derived threshold. Re-calibrate to restore automatic tuning.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !env.store.settings.micEnabled {
            Toggle("IMU side detection", isOn: Binding(
                get: { env.store.settings.imuSideEnabled },
                set: { v in mutateSettings { $0.imuSideEnabled = v } }
            ))
            Text("Classifies taps as left/centre/right using IMU features. Requires side calibration.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let f = env.lastTapEvent?.features {
            LabeledContent("Roll coupling") {
                Text(String(format: "%.3f", f.corr_az_gx))
                    .font(.system(.caption, design: .monospaced))
                    .contentTransition(.numericText())
            }
            LabeledContent("Rise / FWHM") {
                Text(String(format: "%.1f ms / %.1f ms", f.riseTime, f.fwhm))
                    .font(.system(.caption, design: .monospaced))
                    .contentTransition(.numericText())
            }
            LabeledContent("Spectral (lo/mid/hi)") {
                Text(String(format: "%.2f / %.2f / %.2f", f.spec_low, f.spec_mid, f.spec_high))
                    .font(.system(.caption, design: .monospaced))
                    .contentTransition(.numericText())
            }
        }
    }
}
.padding(.vertical, 4)
```

- [ ] **Step 2: Add noiseModelStatus computed property to DetectionView**

Add this computed property inside `DetectionView` (before `body`):

```swift
private var noiseModelStatus: String {
    let m = env.noiseModel
    guard env.store.settings.noiseModelEnabled else { return "Paused" }
    if m.sampleCount == 0 { return "Waiting for noise events…" }
    if m.isActive { return "Active (\(m.sampleCount) samples)" }
    return "Learning (\(m.sampleCount) / \(NoiseModel.activationThreshold))"
}
```

- [ ] **Step 3: Build**

```bash
cd "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap"
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Build app bundle and manually verify UI**

```bash
bash "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap/build-app.sh"
open "/Users/colmo/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Coding/TapTap/TapTap.app"
```

In Detection tab, verify:
1. ML Filter section shows the Sensitivity slider (−1 to +1) when ML filter is on
2. Noise Model section shows toggle + status line ("Waiting for noise events…" initially)
3. No gyro energy gate or rebound check sliders visible at top level — they're inside Advanced ▸
4. Advanced ▸ disclosure group expands to show raw ML threshold, rebound check, gyro energy gate
5. Adjusting the raw ML threshold in Advanced changes `userOverrodeMLThreshold` (visible in debug log if you add a log line, or just verify the slider sticks after closing/reopening)
6. "Reset noise model" button only appears once `sampleCount > 0`

- [ ] **Step 5: Commit**

```bash
git add Sources/TapTap/Views/DetectionView.swift
git commit -m "feat: replace filter sliders with Sensitivity control and Noise Model section in DetectionView"
```

---

## Task 6: End-to-end verification

**Files:** None modified — manual verification only.

- [ ] **Step 1: Run calibration and verify auto-threshold is set**

Open TapTap → Calibration tab → Start Calibration → tap the palm rest 10 times. After completion, open Debug Log. The next tap should show `threshold X.XX` in the ML filter log line, where X.XX ≈ `calibrationFloorScore * 0.85` (a value substantially below the old default of 0.25 if your taps are consistent).

- [ ] **Step 2: Verify genuine taps pass**

With ML filter on and Sensitivity at 0.0, tap the palm rest and keyboard sides firmly 10 times. All should appear in the Debug Log as `"Detected: Single Tap"`. If any are filtered, slide Sensitivity left (toward −1) until they pass.

- [ ] **Step 3: Verify noise model accumulates**

Enable "Learn from noise". Type on the keyboard for 30 seconds. Watch the status line advance from "Learning (0/30)" to "Learning (N/30)" as typing events are strongly rejected. Once it reaches "Active", tap the palm rest — genuine taps should still pass.

- [ ] **Step 4: Verify toggle pauses accumulation**

Turn off "Learn from noise". Type for 10 seconds. Re-enable. The sample count should not have increased during the off period.

- [ ] **Step 5: Verify Reset clears the model**

Press "Reset noise model". Status line returns to "Waiting for noise events…" and sample count resets to 0.

- [ ] **Step 6: Final commit**

```bash
git add .
git commit -m "chore: verified tap detection precision feature end-to-end"
```
