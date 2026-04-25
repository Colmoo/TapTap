# Tap Detection Precision — Design Spec

**Date:** 2026-04-24  
**Status:** Approved

## Problem

When any filter mode is enabled (ML gate, rebound check, gyro energy gate), most genuine taps are filtered out. The user taps on the palm rest and on the sides next to the keyboard. Noise sources are keyboard typing, desk bumps, and trackpad clicks. The current filters are over-aggressive because:

1. The ML scorer uses only 3 features (crestFactor, riseTimeMs, axisRatioZ) and ignores the 17-feature `TapFeatureVector` already computed on every event.
2. The ML threshold (0.25) is hardcoded, not derived from the user's actual calibration data.
3. The system has no model of what noise looks like — it can only describe taps, not distinguish them from non-taps.
4. There are too many manual sliders and toggles to tune.

## Goals

- Genuine taps on the palm rest and keyboard sides consistently pass all filters.
- Typing vibrations, desk bumps, and trackpad clicks are reliably rejected.
- Automatic threshold derivation — no manual slider tuning required after calibration.
- A passive noise model that learns from the environment with zero extra user effort.
- A single Sensitivity slider replaces the current per-filter threshold controls.

## Non-goals

- A separate noise calibration session (rejected in favour of passive accumulation).
- Changes to the gesture classifier, mic TDOA, or action executor.
- Changes to the existing tap calibration flow (10-tap session remains unchanged).

---

## Design

### 1. Full 16-Feature ML Scoring

**Current state:** `CalibrationData.matchScore` computes a z-score over 3 scalars. The `TapFeatureVector` (16 features: riseTime, fwhm, 3 cross-axis correlations, 3 rotational impulse components, 6 channel energies, 3 spectral bands) is computed on every tap but never used for discrimination.

**Change:** Expand `CalibrationData` to store a `featureMean: [Double]` and `featureStd: [Double]` (17-element arrays matching `TapFeatureVector.toArray()`) alongside the existing 3-scalar fields. During `CalibrationData.fit(samples:)`, compute mean and std per feature across all calibration tap events. Update the EMA in `updating(with:)` to also update these arrays.

Replace `matchScore(for:)` with a Mahalanobis-style diagonal score over all 17 features:

```
zScores[i] = (feature[i] - featureMean[i]) / featureStd[i]   (per-feature)
tapScore   = max(0, 1 - mean(abs(zScores)) / 3.0)
```

Features where `featureStd[i] < 1e-6` are skipped (constant during calibration).

**Auto-threshold:** After `CalibrationData.fit(samples:)`, score every calibration sample against the newly fitted model and record the minimum passing score. Store this as `calibrationFloorScore: Double` in `CalibrationData`. At runtime, `mlScoreThreshold` is auto-set to `calibrationFloorScore * 0.85` when the ML filter is enabled and calibration data exists. The manual threshold slider in Advanced still overrides this when the user adjusts it explicitly.

---

### 2. Passive Noise Model

**New type: `NoiseModel`** (in `TapEvent.swift` or a new `NoiseModel.swift`):

```swift
struct NoiseModel: Codable, Sendable {
    let updatedAt: Date
    var sampleCount: Int
    var featureMean: [Double]   // 17 elements — matches TapFeatureVector.toArray()
    var featureStd:  [Double]   // 17 elements
}
```

- Persisted to `UserDefaults` under key `"TapTap.noiseModel.v1"`.
- Fitted and updated via the same EMA (α = 0.05) as `CalibrationData.updating(with:)`.
- Not activated for scoring until `sampleCount >= 30`.

**Accumulation:** In `AppEnvironment.wireUpPipeline()`, after the ML gate rejects an event, check:
- `noiseModelEnabled` is true (new `AppSettings` flag)
- The tap score is < 0.10 (strongly rejected — avoids adding borderline genuine taps)
- The event has a valid `TapFeatureVector`

If all three conditions hold, feed the feature vector into `NoiseModel` via EMA update. Accumulation is gated by `noiseModelEnabled`; turning the toggle off pauses accumulation immediately.

**Scoring:** When `noiseModelEnabled` is true and `noiseModel.sampleCount >= 30`:

```
noiseScore = max(0, 1 - mean(abs((feature - noiseFeatureMean) / noiseFeatureStd)) / 3.0)
rampWeight = min(1.0, (sampleCount - 30) / 70.0)   // 0→1 over samples 30–100
finalScore = tapScore / (tapScore + noiseScore * rampWeight + 1e-9)
```

When `sampleCount < 30` or the toggle is off, `finalScore = tapScore` (falls back to tap-only scoring).

---

### 3. Sensitivity Slider + UI Consolidation

**New `AppSettings` fields:**
- `sensitivityBias: Double = 0.0` — range −1.0 (most permissive) to +1.0 (strictest). Applied as an additive offset to the effective threshold: `effectiveThreshold = autoThreshold + sensitivityBias * 0.15`.
- `noiseModelEnabled: Bool = false` — gates both accumulation and scoring.
- `userOverrodeMLThreshold: Bool = false` — when true, `mlScoreThreshold` is used as-is instead of auto-derived from `calibrationFloorScore`. Reset to false when calibration completes.

**Detection tab changes:**

| Before | After |
|---|---|
| ML filter toggle | ML filter toggle (kept) |
| mlScoreThreshold slider | **Sensitivity** slider Low↔High (maps to sensitivityBias) |
| Gyro energy gate slider | Moved to Advanced |
| Rebound check toggle | Moved to Advanced |
| — | **Noise model** toggle + status line |
| All raw sliders visible | Raw sliders in **Advanced ▸** disclosure group |

**Noise model status line** (below the toggle):
- `"Noise model: learning (12 / 30 samples)"` — while accumulating before activation
- `"Noise model: active (247 samples)"` — once activated
- `"Noise model: paused"` — when toggle is off

The Sensitivity slider replaces the `mlScoreThreshold` slider in the main view. The underlying raw threshold slider remains in Advanced for power users. Manually adjusting it sets `userOverrodeMLThreshold: Bool = true` in `AppSettings`, which prevents auto-threshold from overwriting the value on next launch. Re-running calibration resets this flag and restores auto-threshold.

A **"Reset noise model"** button sits below the noise model status line, clears `NoiseModel` from `UserDefaults`, and resets `sampleCount` to 0. Useful when switching desks or acoustic environments.

---

## Data Flow

```
IMU event
  → threshold crossing
  → TapInputService (rebound check, gyro gate)
  → AppEnvironment.onTapEvent
      ├─ rejected (score < 0.10 AND noiseModelEnabled)  → NoiseModel.update()
      └─ accepted
            → tapScore   (16-feature CalibrationData)
            → noiseScore (16-feature NoiseModel, if active)
            → finalScore = likelihood ratio
            → compare against effectiveThreshold
                  pass → GestureClassifier
                  fail → logged, discarded
```

---

## Files Affected

| File | Change |
|---|---|
| `TapEvent.swift` | Add `NoiseModel` struct; expand `CalibrationData` with `featureMean`, `featureStd`, `calibrationFloorScore`; update `fit`, `updating`, `matchScore` |
| `Models.swift` | Add `sensitivityBias`, `noiseModelEnabled` to `AppSettings` |
| `AppEnvironment.swift` | Wire noise accumulation on rejection; compute `effectiveThreshold`; apply likelihood ratio |
| `CalibrationManager.swift` | Pass feature vectors into `CalibrationData.fit` during phase 1 |
| `Views/DetectionView.swift` | Add Sensitivity slider, Noise model toggle + status line, Advanced disclosure group |

---

## Open Questions / Risks

- **Noise model cold-start:** Until 30 samples accumulate, the system runs tap-only scoring (same as today). Users who rarely trigger false positives may accumulate noise slowly. Acceptable — the system is no worse than today during this period.
- **Feature std collapsing:** If all calibration taps produce near-identical values for a feature (e.g., rotational impulse z is always ~0), `featureStd` will be near zero and that feature is skipped. This is handled by the `< 1e-6` guard but must be verified against real data.
- **EMA drift over many sessions:** The noise model may drift if the acoustic/vibration environment changes significantly (e.g., different desk surface). The toggle gives the user an escape hatch to reset by turning off and clearing the model if needed. A "Reset noise model" button should be added alongside the toggle.
