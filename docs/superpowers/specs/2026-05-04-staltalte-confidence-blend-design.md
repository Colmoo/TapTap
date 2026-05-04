# STA/LTA Confidence Blend — Design Spec
**Date:** 2026-05-04  
**Status:** Approved

## Problem

Soft taps produce a valid energy spike in the IMU signal and cross `tapThresholdG`, so they appear in the debug log. However, because calibration was performed with borderline-detectable taps the resulting Gaussian ML model never learned a reliable shape profile. Consequently, the `matchScore` for soft taps sits below `mlScoreThreshold` (0.25) and the events are dropped. This creates a chicken-and-egg problem: calibration cannot succeed because soft taps are filtered, and soft taps are filtered because calibration did not succeed.

## Goal

Let soft taps through to the gesture classifier and action executor regardless of ML score, by adding a second, calibration-free confidence signal (STA/LTA energy ratio) that runs in parallel with the existing ML scorer. Either path alone is sufficient to pass the gate.

---

## Architecture

No new pipeline stages. The STA/LTA score is computed at window-close time inside `TapInputService`, stored in `TapEvent`, and blended into the existing ML gate in `AppEnvironment`. The rest of the pipeline (gesture classifier, noise model, online learning) is unchanged.

```
IMU samples → ring buffer
                   │
                   ▼ (at closeTrackingWindow)
           STA/LTA energy ratio
                   │
                   ▼
           staLtaScore (0–1) ──┐
                                ├─ max(mlScore, staLtaScore) → gate → classifier
           ML matchScore ───────┘
```

---

## Section 1 — STA/LTA Computation (`TapInputService.swift`)

Computed in `closeTrackingWindow()` after the aligned window is extracted, using samples already in `IMUCircularBuffer`.

**Windows** (relative to `trackingPeakBufIdx`):

| Window | Samples | Duration | Purpose |
|--------|---------|----------|---------|
| STA | 3 | 15 ms | Impulse energy at the tap peak |
| LTA | 100 | 500 ms | Background noise floor before peak |

- STA: indices `[peakBufIdx − 1, peakBufIdx + 1]` (centred on peak)
- LTA: indices `[peakBufIdx − 102, peakBufIdx − 2]` (ends 2 samples before peak, avoids contamination)
- Energy per sample: `dax² + day² + daz²` on the differentiated signal (gravity already removed)

**Ratio and score:**
```
ratio         = mean(STA_energy) / max(mean(LTA_energy), 1e-12)
staLtaScore   = clamp((ratio − 1.0) / 9.0, 0.0, 1.0)
```
`ratio = 1` (no spike above background) → score 0.0.  
`ratio = 10` (very strong spike) → score 1.0.  
A soft genuine tap on a quiet desk typically gives ratio ≈ 5–8; on a noisy lap ≈ 3–5. Both produce scores well above 0.25.

**Warm-up guard:** `IMUCircularBuffer.slice()` already returns fewer items than requested when the buffer hasn't filled yet. If `ltaSamples.count < 50` (less than half the 100-sample LTA window is available — happens in the first ~250 ms after app start), set `staLtaScore = 0.0` so this path never incorrectly passes early events.

---

## Section 2 — `TapEvent` Changes

Add one field:

```swift
let staLtaScore: Double   // 0.0 when STA/LTA is disabled or buffer not warmed up
```

`TapEvent` is in-memory only (never persisted to disk), so no backward-compatibility decoder needed.

---

## Section 3 — Score Blending (`AppEnvironment.swift`)

Inside the ML gate block, replace:

```swift
let tapScore  = data.matchScore(for: event)
// ... noise model ...
let finalScore = tapScore (or noise-adjusted tapScore)
```

With:

```swift
let tapScore     = data.matchScore(for: event)
let staScore     = s.staLtaEnabled ? event.staLtaScore : 0.0
let blendedScore = max(tapScore, staScore)
// ... noise model operates on blendedScore ...
let finalScore   = blendedScore (or noise-adjusted blendedScore)
```

**Noise model interaction:**
- Feed condition (`tapScore < 0.10`) uses the raw ML score, not `blendedScore`. Events that pass via STA/LTA but have poor ML shape are real taps, not noise — they must not train the noise model.
- Online learning condition (`score >= 0.5`) uses `finalScore`. A soft tap with `staLtaScore = 0.55` also updates calibration, gradually teaching the ML model the soft-tap shape.

**Debug log** is updated to show both scores:
```
ML filtered: 0.85g (ml=0.08, sta=0.12, final=0.12, thresh=0.25)
Raw tap accepted: 0.85g (ml=0.08, sta=0.55, final=0.55)
```

---

## Section 4 — Settings (`Models.swift` + `DetectionView.swift`)

`AppSettings` gains:
```swift
var staLtaEnabled: Bool = true
```
Default `true` — the fix is on by default. Backward-compatible decoder (`decodeIfPresent`, fallback `true`).

Exposed as a toggle in `DetectionView` under the existing filter controls, labelled "STA/LTA Energy Gate".

`applySettings()` in `AppEnvironment` pushes `staLtaEnabled` to… nothing, because the value is read inline from `store.settings` at scoring time. No new service property needed.

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/TapTap/TapEvent.swift` | Add `staLtaScore: Double` field |
| `Sources/TapTap/Services/TapInputService.swift` | Compute `staLtaScore` in `closeTrackingWindow()` |
| `Sources/TapTap/AppEnvironment.swift` | Blend STA/LTA into ML gate; update debug log lines |
| `Sources/TapTap/Models.swift` | Add `staLtaEnabled: Bool = true` to `AppSettings` |
| `Sources/TapTap/Views/DetectionView.swift` | Add toggle for `staLtaEnabled` |

No changes to `tap_accel.c`, `GestureClassifier`, `CalibrationManager`, or `BindingStore`.

---

## Success Criteria

1. Soft taps that appear in the debug log are no longer filtered by the ML gate when `staLtaEnabled = true`.
2. A calibration session with normal-force taps now completes successfully.
3. After calibration, the ML path takes over and the debug log shows `ml=` scores rising above the threshold.
4. No regression in false-positive rate on a desk (ambient vibration must still be filtered — its STA/LTA ratio stays near 1.0).
