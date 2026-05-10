# 3-Zone IMU Side Detection

**Date:** 2026-05-09  
**Status:** Approved for implementation

## Problem

The current IMU side classifier (`SideCalibrationData`) is a 1D binary LDA that separates left vs right, with "center" defined as "near the decision boundary." This is unreliable:

- Center is not a calibrated zone — it's just ambiguity between left and right.
- Trackpad-area taps have physically distinct IMU signatures but are forced into the left/right/boundary model.
- The mic TDOA path is being removed; IMU is the sole side-detection signal.

## Goal

Replace the 2-class 1D LDA with a **3-class nearest-centroid Mahalanobis classifier** covering three physically distinct zones:

| Zone | Physical area | Gesture |
|---|---|---|
| Left | Left keyboard area (spread across full left half, ~Q–G column) | `.singleLeft`, `.doubleLeft`, `.tripleLeft` |
| Center | Trackpad + palm rest (spread across full trackpad area) | `.single`, `.double`, `.triple` |
| Right | Right keyboard area (spread across full right half, ~H–] column) | `.singleRight`, `.doubleRight`, `.tripleRight` |

## Why Nearest-Centroid Mahalanobis

For 3 classes with diagonal covariance, the nearest-centroid Mahalanobis decision rule is **equivalent to diagonal LDA** prediction. No matrix inversion or SVD needed — just 3 distance calculations. The model stores:

- One mean vector per class (17 doubles each)
- One pooled within-class variance vector (17 doubles, shared across all 3 classes)

Predict = argmin of squared Mahalanobis distance to each class centroid.

Key discriminating features (from the existing 17-D `TapFeatureVector`):
- `corr_az_gx` — roll coupling: keyboard left/right taps drive roll asymmetrically
- `corr_az_gy` — pitch coupling: trackpad taps couple more strongly into pitch
- `rot_x`, `rot_y` — rotational impulse direction differs by zone
- `energy[3]` (`gx`) — roll gyro energy: highest on keyboard-edge taps

## Calibration Flow

30 taps per zone, spread throughout the entire zone area (not just edges).

**Phase sequence:** left → right → center → fit

| Phase | Instruction | Taps |
|---|---|---|
| Left | Tap across the full left keyboard area | 30 |
| Right | Tap across the full right keyboard area | 30 |
| Center | Tap across the trackpad and palm rest | 30 |

Progress: 0–33% left, 33–67% right, 67–100% center.

Persistence key: `TapTap.sideCalibration.v3` (v2 models are auto-invalidated on load).

## Mic Removal from Side Detection

The `mic.recentSide(since:)` call in `AppEnvironment.wireUpPipeline()` is removed. The mic can continue to be used for tap confirmation (already off by default) but plays no role in side classification.

`micSideThresholdMs` setting is removed from `AppSettings`.

## Changes Required

### `Models.swift` — `AppSettings`
- Remove `micSideThresholdMs` field and its `CodingKey`

### `TapWindow.swift` — `SideCalibrationData`
- Remove: `ldaWeights`, `ldaThreshold`, `ldaMargin`
- Add: `meanLeft: [Double]`, `meanRight: [Double]`, `meanCenter: [Double]`, `pooledVar: [Double]`
- `predictSide(features:)`: compute squared Mahalanobis distance to each centroid, return class with minimum distance
- `fit(leftSamples:rightSamples:centerSamples:)`: compute per-class means and pooled within-class variance across all 3 classes

### `CalibrationManager.swift`
- `SideCalibrationSide` enum: add `.center`
- Add `centerSideFeatures: [[Double]]` collected samples array
- Phase transition: `.left` → `.right` → `.center` → finalize
- `recordSideTap`: route to appropriate array based on current phase
- `sideCalibrationProgress`: 3-phase progress (0–1/3, 1/3–2/3, 2/3–1)
- `sideCalibrationCount`: count of current phase's samples
- `cancelSideCalibration` / `resetSideCalibration`: reset `centerSideFeatures = []` alongside left/right
- `finalizeSideCalibration`: pass 3 arrays to updated `SideCalibrationData.fit`
- Bump persistence key to `v3`

### `AppEnvironment.swift`
- In `wireUpPipeline()`, remove the `micEnabled` side-detection branch:  
  ```swift
  // Before:
  if settings.micEnabled {
      side = self.mic.recentSide(since: ...)
  } else if settings.imuSideEnabled, ...
  // After:
  if settings.imuSideEnabled, ...
  ```
- `applySettings()`: remove `mic.sideThresholdMs = s.micSideThresholdMs` line

### `CalibrationView.swift`
- Add a 3rd calibration instruction card for center/trackpad zone
- Progress bar spans all 3 phases
- Update phase label copy to show "Left → Right → Center"

## What Does Not Change

- `GestureType` enum — `.singleLeft`, `.doubleLeft`, etc. are already defined
- `GestureClassifier` — unchanged
- `TapFeatureVector` — unchanged (same 17 features)
- `ActionExecutor` — unchanged
- Mic confirmation feature — unchanged (separate from side detection)
- `imuSideEnabled` setting name — unchanged
