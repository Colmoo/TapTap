# IMU Side Detection Accuracy — Design Spec

**Date:** 2026-05-08  
**Status:** Approved

## Problem

The existing IMU side classifier (`SideCalibrationData`) uses raw Euclidean nearest-centroid over all 17 features. Because features have wildly different scales (`riseTime` is 2–20 ms; `corr_az_gx` is [−1, 1]), the large-scale features dominate the distance calculation and drown out the gyroscope features that actually carry the left/right signal. Result: left fires as right, center is never detected.

Additionally, the left/right binding zones in the UI are gated behind `micEnabled`, even though IMU side detection doesn't require the microphone.

---

## Design

### 1. Algorithm — Diagonal LDA replacing nearest-centroid

Replace `SideCalibrationData`'s nearest-centroid classifier with **diagonal Linear Discriminant Analysis**.

**Fit time** (from 30 left + 30 right calibration samples):

For each feature dimension `i`:
1. Compute per-class means: `μ_L[i]`, `μ_R[i]`
2. Compute pooled within-class variance:  
   `σ²[i] = (Σ_L(x−μ_L)² + Σ_R(x−μ_R)²) / (n_L + n_R − 2)`
3. LDA weight: `w[i] = (μ_L[i] − μ_R[i]) / max(σ²[i], 1e-9)`
4. Decision threshold (midpoint of projected class means):  
   `t = (w·μ_L + w·μ_R) / 2`
5. Within-class spread on the LDA axis:  
   `σ_lda = sqrt((Σ_L(w·x − w·μ_L)² + Σ_R(w·x − w·μ_R)²) / (n_L + n_R − 2))`
6. Center margin: `margin = 0.7 × σ_lda`

**Predict time:**

```
score = w · x          (dot product)
if score > t + margin  → .left
if score < t − margin  → .right
else                   → .center
```

The `w[i]` weights naturally up-weight informative features (`corr_az_gx`, `rot_x`, `energy_gx`) and near-zero-weight noise features (`riseTime`, spectral bands) — no manual feature selection needed.

### 2. Storage — `SideCalibrationData` fields

**Remove:** `leftCentroid: [Double]`, `rightCentroid: [Double]`  
**Add:**
- `ldaWeights: [Double]` — LDA projection vector (17 elements)
- `ldaThreshold: Double` — midpoint between projected class means
- `ldaMargin: Double` — half-width of center zone

Persistence key bumped: `TapTap.sideCalibration.v1` → `TapTap.sideCalibration.v2` to force re-calibration (old model is incompatible).

Calibration sample count: `CalibrationManager.targetSideCount` 20 → 30 per side.

### 3. Bindings UI — unlock left/right without mic

**`active` condition** in `KeyboardMapView` / `TapZoneColumn`:  
`micEnabled` → `micEnabled || imuSideEnabled`

**Badge** in `KeyboardMapView`:  
Show "9 gestures" when `micEnabled || imuSideEnabled`; show "3 gestures" otherwise.

**`MicUpsellBanner`:**  
- Rename to `SideDetectionUpsellBanner`
- Body text: "Enable microphone detection or calibrate IMU side detection to unlock 9 gestures."
- "Enable Mic" button unchanged; add a second "Calibrate IMU" button that navigates to the side calibration screen (via existing `imuSideEnabled` toggle path, or directly opens calibration if not yet done).

---

## Files changed

| File | Change |
|---|---|
| `Sources/TapTap/TapWindow.swift` | Replace `SideCalibrationData` fields + `fit()` + `predictSide()` with LDA |
| `Sources/TapTap/Services/CalibrationManager.swift` | `targetSideCount` 20 → 30; bump persistence key |
| `Sources/TapTap/Views/BindingsView.swift` | `active` condition, badge, banner |

No changes to `AppEnvironment`, `GestureClassifier`, `TapEvent`, or `Models`.

---

## Out of scope

- Center sample collection during calibration (not needed — margin is derived from L/R spread)
- Changes to mic-based side detection
- Any changes to the tap detection pipeline itself
