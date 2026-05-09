# IMU Side Detection Accuracy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw-Euclidean nearest-centroid side classifier with diagonal LDA so left/right/center IMU side detection actually works, and unlock left/right binding zones without requiring the microphone.

**Architecture:** Diagonal LDA weights each feature by its between-class difference divided by its pooled within-class variance — naturally down-weighting noisy features (riseTime, spectral bands) and up-weighting the gyro roll features (corr_az_gx, rot_x) that actually carry the left/right signal. The center class is determined by proximity to the LDA decision boundary. No new files are needed; three existing files are modified.

**Tech Stack:** Swift, SwiftUI — no new dependencies.

---

## File map

| File | What changes |
|---|---|
| `Sources/TapTap/TapWindow.swift` | Replace `SideCalibrationData` struct (fields, `fit()`, `predictSide()`); remove unused `euclidean()` helper |
| `Sources/TapTap/Services/CalibrationManager.swift` | `targetSideCount` 20 → 30; `sidePersistenceKey` v1 → v2 |
| `Sources/TapTap/Views/BindingsView.swift` | `active` condition, badge, upsell banner |

---

## Task 1: Replace SideCalibrationData with diagonal LDA

**Files:**
- Modify: `Sources/TapTap/TapWindow.swift:170-210`

The current struct at lines 170–210 stores `leftCentroid` and `rightCentroid` and computes Euclidean distance. Replace the entire block (including the `private func euclidean` at the bottom) with the implementation below.

- [ ] **Step 1: Replace the SideCalibrationData block and euclidean helper**

Delete lines 170–210 of `Sources/TapTap/TapWindow.swift` (from `// MARK: - SideCalibrationData` through the closing brace of `private func euclidean`) and replace with:

```swift
// MARK: - SideCalibrationData

/// Diagonal-LDA classifier for left/right/center side detection via IMU features.
///
/// Fit by calling `fit(leftSamples:rightSamples:)` with ~30 labelled feature
/// vectors per side.  `predictSide` returns `.center` when the tap lands near
/// the decision boundary (within `ldaMargin` of `ldaThreshold`).
struct SideCalibrationData: Codable, Sendable {
    let calibratedAt: Date
    let sampleCount: Int
    /// LDA projection vector — one weight per feature (17 elements).
    let ldaWeights: [Double]
    /// Midpoint between the projected class means.
    /// score > threshold + margin → .left
    /// score < threshold - margin → .right
    /// otherwise                 → .center
    let ldaThreshold: Double
    /// Half-width of the center zone (0.7 × within-class std on the LDA axis).
    let ldaMargin: Double

    // MARK: - Prediction

    func predictSide(features: TapFeatureVector) -> TapSide {
        let fv = features.toArray()
        guard fv.count == ldaWeights.count else { return .center }
        let score = zip(fv, ldaWeights).reduce(0.0) { $0 + $1.0 * $1.1 }
        if score > ldaThreshold + ldaMargin { return .left }
        if score < ldaThreshold - ldaMargin { return .right }
        return .center
    }

    // MARK: - Factory

    static func fit(leftSamples: [[Double]], rightSamples: [[Double]]) -> SideCalibrationData? {
        guard !leftSamples.isEmpty, !rightSamples.isEmpty,
              let dim = leftSamples.first?.count, dim > 0,
              rightSamples.first?.count == dim else { return nil }

        let nL = Double(leftSamples.count)
        let nR = Double(rightSamples.count)

        // Per-class means
        var muL = [Double](repeating: 0, count: dim)
        var muR = [Double](repeating: 0, count: dim)
        for s in leftSamples  { for i in 0..<dim { muL[i] += s[i] / nL } }
        for s in rightSamples { for i in 0..<dim { muR[i] += s[i] / nR } }

        // Pooled within-class variance per feature
        let denom = max(nL + nR - 2, 1)
        var pooledVar = [Double](repeating: 0, count: dim)
        for s in leftSamples  { for i in 0..<dim { pooledVar[i] += pow(s[i] - muL[i], 2) / denom } }
        for s in rightSamples { for i in 0..<dim { pooledVar[i] += pow(s[i] - muR[i], 2) / denom } }

        // LDA weight: between-class difference / pooled variance
        let w = (0..<dim).map { i in (muL[i] - muR[i]) / max(pooledVar[i], 1e-9) }

        // Projected class means → decision threshold at midpoint
        let projL = zip(w, muL).reduce(0.0) { $0 + $1.0 * $1.1 }
        let projR = zip(w, muR).reduce(0.0) { $0 + $1.0 * $1.1 }
        let threshold = (projL + projR) / 2

        // Within-class spread on the LDA axis → center margin
        var ssW = 0.0
        for s in leftSamples  { let p = zip(w, s).reduce(0.0) { $0 + $1.0 * $1.1 }; ssW += pow(p - projL, 2) }
        for s in rightSamples { let p = zip(w, s).reduce(0.0) { $0 + $1.0 * $1.1 }; ssW += pow(p - projR, 2) }
        let sigmaLDA = (ssW / denom).squareRoot()
        let margin   = 0.7 * sigmaLDA

        return SideCalibrationData(
            calibratedAt: Date(),
            sampleCount:  leftSamples.count + rightSamples.count,
            ldaWeights:   w,
            ldaThreshold: threshold,
            ldaMargin:    margin
        )
    }
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!` with no `error:` lines. If there are errors they will be because a call site still references `leftCentroid` or `rightCentroid` — grep for them and remove.

- [ ] **Step 3: Commit**

```bash
git add Sources/TapTap/TapWindow.swift
git commit -m "feat: replace nearest-centroid side classifier with diagonal LDA"
```

---

## Task 2: Bump calibration sample count and persistence key

**Files:**
- Modify: `Sources/TapTap/Services/CalibrationManager.swift:91-92`

- [ ] **Step 1: Update targetSideCount and sidePersistenceKey**

In `CalibrationManager`, find these two lines (around line 91–92):

```swift
private static let sidePersistenceKey = "TapTap.sideCalibration.v1"
static let targetSideCount = 20  // taps per side
```

Replace with:

```swift
private static let sidePersistenceKey = "TapTap.sideCalibration.v2"
static let targetSideCount = 30  // taps per side
```

The key change from v1 → v2 causes the app to ignore any existing (now-incompatible) saved model and start fresh. The sample count increase gives the LDA more data to estimate within-class variance reliably.

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TapTap/Services/CalibrationManager.swift
git commit -m "feat: bump side calibration to 30 samples/side, invalidate v1 model"
```

---

## Task 3: Unlock left/right binding zones for IMU side detection

**Files:**
- Modify: `Sources/TapTap/Views/BindingsView.swift`

There are four changes in this file:
1. `KeyboardMapView.micEnabled` computed property → `sideEnabled` covering both mic and IMU
2. The "9 gestures / 3 gestures" badge condition
3. `TapZoneColumn` `active` parameter passed for left and right columns
4. The `MicUpsellBanner` body — update text and add "Enable IMU" button

- [ ] **Step 1: Update KeyboardMapView**

Find `struct KeyboardMapView` (around line 33). Replace the `micEnabled` computed property and the `body` property with:

```swift
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
```

- [ ] **Step 2: Update TapZoneColumn's inactive overlay**

In `TapZoneColumn` (around line 175), the inactive overlay currently shows a mic icon. Update the overlay block so it no longer implies the mic is the only path:

```swift
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
```

- [ ] **Step 3: Update MicUpsellBanner**

Replace the entire `MicUpsellBanner` struct (lines 285–322) with:

```swift
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
```

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/TapTap/Views/BindingsView.swift
git commit -m "feat: unlock left/right binding zones for IMU side detection"
```

---

## Task 4: Build app bundle and smoke-test

- [ ] **Step 1: Build the app bundle**

```bash
bash build-app.sh && open TapTap.app
```

- [ ] **Step 2: Verify bindings UI**

Open the app → Bindings tab.
- With mic off and IMU side off: left/right columns should be dimmed, banner visible with both buttons.
- Click "Enable IMU": left/right columns should activate immediately (9-gestures badge with gyroscope icon), banner disappears.
- Clicking any left/right gesture slot should open the binding editor sheet.

- [ ] **Step 3: Verify side calibration still works**

Go to Detection tab → toggle IMU Side Detection on (if not already on from step 2) → navigate to Calibration tab → run side calibration. It should now collect 30 samples per side (was 20). After completion, tapping the lid should classify left/right/center correctly.

- [ ] **Step 4: Final commit**

If any last fixes were needed during smoke-test, commit them now:

```bash
git add -p
git commit -m "fix: smoke-test corrections for IMU side detection"
```
