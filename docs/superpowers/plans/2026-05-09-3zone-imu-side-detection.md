# 3-Zone IMU Side Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2-class 1D LDA side classifier with a 3-class nearest-centroid Mahalanobis classifier covering left keyboard / right keyboard / trackpad zones, and remove mic from the side-detection path entirely.

**Architecture:** `SideCalibrationData` gains three calibrated centroids (left, right, center) plus a pooled variance vector; prediction is argmin of squared Mahalanobis distance to each centroid. `CalibrationManager` gains a third calibration phase (center/trackpad) after left and right. The mic TDOA side-detection branch in `AppEnvironment` is deleted.

**Tech Stack:** Swift, SwiftUI, UserDefaults (JSON persistence), no external libraries.

---

## File Map

| File | Change |
|---|---|
| `Sources/TapTap/TapWindow.swift` | Replace `SideCalibrationData` struct with 3-class model |
| `Sources/TapTap/Services/CalibrationManager.swift` | Add `.center` to `SideCalibrationSide`; add third calibration phase |
| `Sources/TapTap/Models.swift` | Remove `micSideThresholdMs` from `AppSettings` |
| `Sources/TapTap/AppEnvironment.swift` | Remove mic side-detection branch from pipeline; remove `mic.sideThresholdMs` from `applySettings` |
| `Sources/TapTap/Views/DetectionView.swift` | Remove "Centre threshold" slider for `micSideThresholdMs` |
| `Sources/TapTap/Views/CalibrationView.swift` | Update side calibration section to show 3 phases |

---

## Task 1 — Replace `SideCalibrationData` with 3-class Mahalanobis model

**Files:**
- Modify: `Sources/TapTap/TapWindow.swift:177-246`

**Context:** The current struct stores 1D LDA weights (`ldaWeights`, `ldaThreshold`, `ldaMargin`) and fits only left vs right. The new struct stores one mean vector per class (17 doubles) plus a shared pooled-variance vector (17 doubles). Prediction = argmin of squared Mahalanobis distance.

- [ ] **Step 1: Replace the `SideCalibrationData` struct**

In `Sources/TapTap/TapWindow.swift`, delete everything from `// MARK: - SideCalibrationData` (line 170) to the end of the file (line 246) and replace with:

```swift
// MARK: - SideCalibrationData

/// 3-class nearest-centroid Mahalanobis classifier for IMU side detection.
///
/// Stores one calibrated mean vector per zone (left keyboard / right keyboard /
/// trackpad+palm-rest) plus a shared pooled within-class variance vector.
/// Prediction: zone with the smallest squared Mahalanobis distance wins.
///
/// This is equivalent to diagonal-covariance LDA classification — no matrix
/// inversion required, just three dot products.
struct SideCalibrationData: Codable, Sendable {
    let calibratedAt: Date
    let sampleCount: Int
    /// Pooled within-class variance per feature (17 elements, shared across classes).
    let pooledVar: [Double]
    let meanLeft:   [Double]
    let meanRight:  [Double]
    let meanCenter: [Double]

    // MARK: - Prediction

    func predictSide(features: TapFeatureVector) -> TapSide {
        let fv = features.toArray()
        guard fv.count == pooledVar.count else { return .center }
        let dL = mahalanobisSq(fv, mean: meanLeft)
        let dR = mahalanobisSq(fv, mean: meanRight)
        let dC = mahalanobisSq(fv, mean: meanCenter)
        if dL <= dR && dL <= dC { return .left }
        if dR < dL  && dR <= dC { return .right }
        return .center
    }

    private func mahalanobisSq(_ x: [Double], mean: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<x.count {
            guard pooledVar[i] > 1e-9 else { continue }
            let d = x[i] - mean[i]
            sum += d * d / pooledVar[i]
        }
        return sum
    }

    // MARK: - Factory

    static func fit(
        leftSamples:   [[Double]],
        rightSamples:  [[Double]],
        centerSamples: [[Double]]
    ) -> SideCalibrationData? {
        guard !leftSamples.isEmpty, !rightSamples.isEmpty, !centerSamples.isEmpty,
              let dim = leftSamples.first?.count, dim > 0,
              rightSamples.first?.count  == dim,
              centerSamples.first?.count == dim
        else { return nil }

        let nL = Double(leftSamples.count)
        let nR = Double(rightSamples.count)
        let nC = Double(centerSamples.count)

        var muL = [Double](repeating: 0, count: dim)
        var muR = [Double](repeating: 0, count: dim)
        var muC = [Double](repeating: 0, count: dim)
        for s in leftSamples   { for i in 0..<dim { muL[i] += s[i] / nL } }
        for s in rightSamples  { for i in 0..<dim { muR[i] += s[i] / nR } }
        for s in centerSamples { for i in 0..<dim { muC[i] += s[i] / nC } }

        // Pooled within-class variance (denominator = N_total - 3 classes)
        let denom = max(nL + nR + nC - 3, 1)
        var pooledVar = [Double](repeating: 0, count: dim)
        for s in leftSamples   { for i in 0..<dim { pooledVar[i] += pow(s[i] - muL[i], 2) / denom } }
        for s in rightSamples  { for i in 0..<dim { pooledVar[i] += pow(s[i] - muR[i], 2) / denom } }
        for s in centerSamples { for i in 0..<dim { pooledVar[i] += pow(s[i] - muC[i], 2) / denom } }

        return SideCalibrationData(
            calibratedAt: Date(),
            sampleCount:  leftSamples.count + rightSamples.count + centerSamples.count,
            pooledVar:    pooledVar,
            meanLeft:     muL,
            meanRight:    muR,
            meanCenter:   muC
        )
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: errors about `ldaWeights` / `ldaThreshold` / `ldaMargin` being missing in `CalibrationManager.swift` (we haven't updated the call site yet). That's fine — this confirms the old API is gone. There should be **no** errors inside `TapWindow.swift` itself.

If you see errors _within_ `TapWindow.swift`, fix those before continuing.

- [ ] **Step 3: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/TapWindow.swift
git commit -m "feat: replace SideCalibrationData with 3-class Mahalanobis model"
```

---

## Task 2 — Add center phase to `CalibrationManager`

**Files:**
- Modify: `Sources/TapTap/Services/CalibrationManager.swift`

**Context:** `SideCalibrationSide` currently has `.left` and `.right`. We add `.center`. `CalibrationManager` tracks `leftSideFeatures` and `rightSideFeatures`; we add `centerSideFeatures`. The phase transitions become left → right → center → finalize. The persistence key bumps to `v3` to invalidate old 2-class models (users must recalibrate).

- [ ] **Step 1: Update `SideCalibrationSide` enum**

At the top of `Sources/TapTap/Services/CalibrationManager.swift`, change:

```swift
// Before:
enum SideCalibrationSide: Equatable {
    case left, right
}

// After:
enum SideCalibrationSide: Equatable {
    case left, right, center
}
```

- [ ] **Step 2: Bump the persistence key and add `centerSideFeatures`**

In the `// MARK: - Side calibration state (Step 10)` block, make these changes:

```swift
// Before:
private static let sidePersistenceKey = "TapTap.sideCalibration.v2"
static let targetSideCount = 30  // taps per side

private(set) var sideCalibrationData: SideCalibrationData? = nil
private(set) var sidePhase: SideCalibrationSide? = nil  // nil = not calibrating
private(set) var leftSideFeatures:  [[Double]] = []
private(set) var rightSideFeatures: [[Double]] = []

// After:
private static let sidePersistenceKey = "TapTap.sideCalibration.v3"
static let targetSideCount = 30  // taps per zone

private(set) var sideCalibrationData: SideCalibrationData? = nil
private(set) var sidePhase: SideCalibrationSide? = nil  // nil = not calibrating
private(set) var leftSideFeatures:   [[Double]] = []
private(set) var rightSideFeatures:  [[Double]] = []
private(set) var centerSideFeatures: [[Double]] = []
```

- [ ] **Step 3: Update `sideCalibrationProgress` and `sideCalibrationCount`**

```swift
// Before:
var sideCalibrationProgress: Double {
    guard let phase = sidePhase else { return 0 }
    switch phase {
    case .left:  return Double(leftSideFeatures.count)  / Double(Self.targetSideCount) * 0.5
    case .right: return 0.5 + Double(rightSideFeatures.count) / Double(Self.targetSideCount) * 0.5
    }
}
var sideCalibrationCount: Int {
    sidePhase == .left ? leftSideFeatures.count : rightSideFeatures.count
}

// After:
var sideCalibrationProgress: Double {
    guard let phase = sidePhase else { return 0 }
    let t = Double(Self.targetSideCount)
    switch phase {
    case .left:   return Double(leftSideFeatures.count)   / t / 3.0
    case .right:  return 1.0/3.0 + Double(rightSideFeatures.count)  / t / 3.0
    case .center: return 2.0/3.0 + Double(centerSideFeatures.count) / t / 3.0
    }
}
var sideCalibrationCount: Int {
    switch sidePhase {
    case .left:   return leftSideFeatures.count
    case .right:  return rightSideFeatures.count
    case .center: return centerSideFeatures.count
    case nil:     return 0
    }
}
```

- [ ] **Step 4: Update `startSideCalibration`**

```swift
// Before:
func startSideCalibration() {
    leftSideFeatures  = []
    rightSideFeatures = []
    sidePhase         = .left
}

// After:
func startSideCalibration() {
    leftSideFeatures   = []
    rightSideFeatures  = []
    centerSideFeatures = []
    sidePhase          = .left
}
```

- [ ] **Step 5: Update `recordSideTap`**

```swift
// Before:
func recordSideTap(features: TapFeatureVector) {
    guard let phase = sidePhase else { return }
    let fv = features.toArray()
    switch phase {
    case .left:
        leftSideFeatures.append(fv)
        if leftSideFeatures.count >= Self.targetSideCount { sidePhase = .right }
    case .right:
        rightSideFeatures.append(fv)
        if rightSideFeatures.count >= Self.targetSideCount { finalizeSideCalibration() }
    }
}

// After:
func recordSideTap(features: TapFeatureVector) {
    guard let phase = sidePhase else { return }
    let fv = features.toArray()
    switch phase {
    case .left:
        leftSideFeatures.append(fv)
        if leftSideFeatures.count >= Self.targetSideCount { sidePhase = .right }
    case .right:
        rightSideFeatures.append(fv)
        if rightSideFeatures.count >= Self.targetSideCount { sidePhase = .center }
    case .center:
        centerSideFeatures.append(fv)
        if centerSideFeatures.count >= Self.targetSideCount { finalizeSideCalibration() }
    }
}
```

- [ ] **Step 6: Update `cancelSideCalibration`**

```swift
// Before:
func cancelSideCalibration() {
    leftSideFeatures  = []
    rightSideFeatures = []
    sidePhase         = nil
}

// After:
func cancelSideCalibration() {
    leftSideFeatures   = []
    rightSideFeatures  = []
    centerSideFeatures = []
    sidePhase          = nil
}
```

- [ ] **Step 7: Update `finalizeSideCalibration`**

```swift
// Before:
private func finalizeSideCalibration() {
    guard let data = SideCalibrationData.fit(
        leftSamples: leftSideFeatures,
        rightSamples: rightSideFeatures
    ) else { return }
    sideCalibrationData = data
    sidePhase           = nil
    persistSideData(data)
}

// After:
private func finalizeSideCalibration() {
    guard let data = SideCalibrationData.fit(
        leftSamples:   leftSideFeatures,
        rightSamples:  rightSideFeatures,
        centerSamples: centerSideFeatures
    ) else { return }
    sideCalibrationData = data
    sidePhase           = nil
    persistSideData(data)
}
```

- [ ] **Step 8: Verify build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: errors about `micSideThresholdMs` in `AppEnvironment` and `DetectionView` (not yet removed). No errors in `CalibrationManager.swift` or `TapWindow.swift`.

- [ ] **Step 9: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/Services/CalibrationManager.swift
git commit -m "feat: add center zone to side calibration (3-phase: left→right→center)"
```

---

## Task 3 — Remove `micSideThresholdMs` from `AppSettings`

**Files:**
- Modify: `Sources/TapTap/Models.swift`

**Context:** `micSideThresholdMs` controlled the TDOA center-classification threshold in `MicInputService`. With mic removed from side detection, this setting has no effect. Remove it from `AppSettings` to avoid dead state.

- [ ] **Step 1: Remove the property, coding key, and decoder line**

In `Sources/TapTap/Models.swift`, make three deletions:

**1a — Remove the property** (in the `struct AppSettings` body):
```swift
// Delete this line:
var micSideThresholdMs: Double = 0.2
```

**1b — Remove the coding key** (in `enum CodingKeys`):
```swift
// Before:
case micEnabled, micThresholdMultiplier, micSideThresholdMs

// After:
case micEnabled, micThresholdMultiplier
```

**1c — Remove the decoder assignment** (in `init(from decoder:)`):
```swift
// Delete this line:
micSideThresholdMs        = (try? c.decode(Double.self, forKey: .micSideThresholdMs))        ?? 0.2
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: errors in `AppEnvironment.swift` (`mic.sideThresholdMs`) and `DetectionView.swift` (`micSideThresholdMs`) — those are the remaining two files. No errors in `Models.swift`.

- [ ] **Step 3: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/Models.swift
git commit -m "feat: remove micSideThresholdMs setting (mic no longer used for side detection)"
```

---

## Task 4 — Remove mic side detection from `AppEnvironment`

**Files:**
- Modify: `Sources/TapTap/AppEnvironment.swift`

**Context:** The pipeline has two call sites to update. In `applySettings()`, the line `mic.sideThresholdMs = s.micSideThresholdMs` must go. In `wireUpPipeline()`, the `if settings.micEnabled { side = mic.recentSide(...) } else if ...` block collapses to just the IMU branch.

- [ ] **Step 1: Remove `mic.sideThresholdMs` from `applySettings()`**

In `Sources/TapTap/AppEnvironment.swift`, in the `applySettings()` function:

```swift
// Before:
mic.thresholdMultiplier = s.micThresholdMultiplier
mic.sideThresholdMs     = s.micSideThresholdMs

// After:
mic.thresholdMultiplier = s.micThresholdMultiplier
```

- [ ] **Step 2: Collapse side-detection block in `wireUpPipeline()`**

Find the comment `// Tap accepted — forward to gesture classifier with side detection.` and replace the entire side-detection block:

```swift
// Before:
let side: TapSide
let settings = self.store.settings
if settings.micEnabled {
    side = self.mic.recentSide(since: event.timestamp.addingTimeInterval(-0.2))
} else if settings.imuSideEnabled,
          let features = event.features,
          let sideModel = self.calibration.sideCalibrationData {
    side = sideModel.predictSide(features: features)
} else {
    side = .center
}

// After:
let side: TapSide
let settings = self.store.settings
if settings.imuSideEnabled,
   let features = event.features,
   let sideModel = self.calibration.sideCalibrationData {
    side = sideModel.predictSide(features: features)
} else {
    side = .center
}
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: one remaining error in `DetectionView.swift` about `micSideThresholdMs`. No errors in `AppEnvironment.swift`.

- [ ] **Step 4: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/AppEnvironment.swift
git commit -m "feat: remove mic side-detection branch from pipeline"
```

---

## Task 5 — Remove `micSideThresholdMs` slider from `DetectionView`

**Files:**
- Modify: `Sources/TapTap/Views/DetectionView.swift`

**Context:** There is a "Centre threshold" `SliderRow` bound to `micSideThresholdMs` at lines 104–115. This row and its explanatory `Text` below it must be deleted.

- [ ] **Step 1: Delete the slider and its caption**

In `Sources/TapTap/Views/DetectionView.swift`, delete this block (lines ~104–115):

```swift
// Delete all of this:
SliderRow(
    label: "Centre threshold",
    value: Binding(
        get: { env.store.settings.micSideThresholdMs },
        set: { v in mutateSettings { $0.micSideThresholdMs = v } }
    ),
    range: 0.05...0.6,
    format: "%.2f ms"
)
Text("Max TDOA to classify as a centre tap. Max possible on a MacBook ≈ 0.82 ms.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 2: Verify clean build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors or warnings.

- [ ] **Step 3: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/Views/DetectionView.swift
git commit -m "feat: remove mic centre-threshold slider (mic no longer controls side detection)"
```

---

## Task 6 — Update `CalibrationView` for 3-phase side calibration

**Files:**
- Modify: `Sources/TapTap/Views/CalibrationView.swift`

**Context:** The `sideCalibrationSection` currently shows 2 phases with an `isLeft` bool. Replace it with a 3-phase switch that handles `.left`, `.right`, and `.center`. The idle state description also needs updating (2-zone → 3-zone).

- [ ] **Step 1: Replace `sideCalibrationSection`**

In `Sources/TapTap/Views/CalibrationView.swift`, replace the entire `sideCalibrationSection` computed property:

```swift
@ViewBuilder
private var sideCalibrationSection: some View {
    Section("Side Detection (IMU)") {
        if env.calibration.isSideCalibrating {
            let phase = env.calibration.sidePhase ?? .left
            let step: Int   = phase == .left ? 1 : phase == .right ? 2 : 3
            let title       = phase == .left ? "Tap LEFT zone"   : phase == .right ? "Tap RIGHT zone"   : "Tap CENTER zone"
            let subtitle    = phase == .left
                ? "Spread \(CalibrationManager.targetSideCount) taps across the full left keyboard area."
                : phase == .right
                    ? "Spread \(CalibrationManager.targetSideCount) taps across the full right keyboard area."
                    : "Spread \(CalibrationManager.targetSideCount) taps across the trackpad and palm rest."
            let label       = phase == .left ? "Left taps" : phase == .right ? "Right taps" : "Center taps"

            phaseHeader(step: step, title: title, subtitle: subtitle, totalSteps: 3)
            progressRow(
                label: label,
                value: Double(env.calibration.sideCalibrationCount) / Double(CalibrationManager.targetSideCount),
                current: env.calibration.sideCalibrationCount,
                target: CalibrationManager.targetSideCount
            )
            Text("Tap naturally across the whole zone — not just the edges.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) {
                env.calibration.cancelSideCalibration()
            }
        } else if let data = env.calibration.sideCalibrationData {
            LabeledContent("State") {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Calibrated (\(data.sampleCount) taps)")
                }
            }
            LabeledContent("Calibrated") {
                Text(data.calibratedAt, style: .date)
                    .foregroundStyle(.secondary)
            }
            Text("Enable \"IMU side detection\" in the Detection tab to use this model.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Recalibrate Sides") {
                    env.calibration.startSideCalibration()
                    if !env.isListening { env.startListening() }
                }
                .buttonStyle(.borderedProminent)
                Button("Reset", role: .destructive) {
                    env.calibration.resetSideCalibration()
                }
            }
        } else {
            Text("Train a 3-zone classifier (left keyboard / right keyboard / trackpad) using IMU cross-axis correlations. Tap each zone \(CalibrationManager.targetSideCount) times spread across the whole area.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Start Side Calibration") {
                env.calibration.startSideCalibration()
                if !env.isListening { env.startListening() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

- [ ] **Step 2: Verify clean build**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors or warnings.

- [ ] **Step 3: Build the app bundle**

```bash
cd /Users/colmo/Desktop/Coding/TapTap && bash build-app.sh
```

Expected: `TapTap.app` created in project root.

- [ ] **Step 4: Commit**

```bash
cd /Users/colmo/Desktop/Coding/TapTap
git add Sources/TapTap/Views/CalibrationView.swift
git commit -m "feat: update side calibration UI for 3 zones (left / right / center)"
```

---

## Post-implementation: Recalibrate side detection

After launching the new app bundle:

1. Open TapTap → Calibration tab → Side Detection section
2. Click **Start Side Calibration**
3. Phase 1 (Left): tap 30 times spread across the full left keyboard half
4. Phase 2 (Right): tap 30 times spread across the full right keyboard half
5. Phase 3 (Center): tap 30 times spread across the trackpad + palm rest
6. Calibration completes automatically → enable "IMU side detection" in Detection tab
7. Test by tapping each zone and observing the detected gesture side in the debug log
