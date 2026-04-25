import Foundation

/// Rich feature vector captured from a single knock waveform.
///
/// `TapInputService` opens an 80 ms tracking window on the first threshold
/// crossing, then emits a `TapEvent` containing the true waveform peak and shape.
/// This lets downstream code (the classifier, calibration manager) work with
/// the morphological shape of the tap rather than just magnitude.
struct TapEvent: Codable, Sendable {
    /// Wall-clock time of the initial threshold crossing.
    let timestamp: Date
    /// Maximum acceleration magnitude (√x²+y²+z², in g) seen during the window.
    let peakMagnitude: Double
    /// Axis components **at** the peak sample.
    let peakX: Double
    let peakY: Double
    let peakZ: Double
    /// Gyroscope magnitude (√ωx²+ωy²+ωz², rad/s) sampled at window close
    /// (~80 ms after the initial threshold crossing). By that point the brief
    /// angular impulse from the tap impact has subsided, so this reads near
    /// zero for genuine taps and remains elevated during whole-laptop movement.
    /// Zero when gyroscope is unavailable.
    let closingGyroMagnitude: Double

    /// The ratio of the peak magnitude to the RMS average magnitude during the tracking window.
    /// A high crest factor indicates a sharp morphological tap; a low crest factor indicates a dull bump.
    let crestFactor: Double
    /// The time in milliseconds from the threshold crossing to the absolute peak.
    let riseTimeMs: Double
    /// Full feature vector computed from the aligned differentiated window (Steps 5–9).
    /// Nil when gyroscope is unavailable or the buffer hasn't warmed up yet.
    var features: TapFeatureVector?

    /// Fraction of total magnitude carried by the Z axis.
    ///
    /// Taps on the lid of a closed MacBook are typically Z-dominant (the lid is
    /// perpendicular to the Z axis of the IMU). Table thuds and incidental
    /// vibrations tend to be more evenly distributed across all three axes,
    /// making `axisRatioZ` a useful discriminating feature.
    var axisRatioZ: Double { abs(peakZ) / max(peakMagnitude, 1e-6) }
}

// MARK: - Calibration model

/// Gaussian statistical model fit from a guided calibration session.
///
/// Features are modelled independently (diagonal covariance assumption):
///   - `crestFactor` — how sharp the user's tap shape is
///   - `riseTimeMs`  — how quickly the tap impacts
///   - `axisRatioZ`  — directional shape
///
/// Use `matchScore(for:)` to score a live event against the fitted distribution.
/// High-scoring events closely resemble the calibration profile; low-scoring
/// events (different shape) are more likely to be noise.
struct CalibrationData: Codable, Sendable {
    let calibratedAt: Date
    let sampleCount: Int

    // Gaussian fit — Crest Factor
    let meanCrestFactor: Double
    let stdCrestFactor: Double
    // Gaussian fit — Rise Time
    let meanRiseTime: Double
    let stdRiseTime: Double
    // Gaussian fit — Z-axis dominance ratio
    let meanAxisZ: Double
    let stdAxisZ: Double
    // Timing model — learned from multi-tap calibration phases (nil if not yet calibrated)
    var learnedDoubleTapWindowMs: Double?
    var learnedTripleTapWindowMs: Double?

    // MARK: Derived

    /// Match score in **[0, 1]** based on morphological shape (crest factor & rise time).
    ///
    /// A score of 1.0 means the event is exactly at the calibrated mean;
    /// a score of 0.0 means it is ≥ 3 σ away.
    func matchScore(for event: TapEvent) -> Double {
        let zCrest = stdCrestFactor > 1e-6 ? (event.crestFactor - meanCrestFactor) / stdCrestFactor : 0
        let zRise = stdRiseTime > 1e-6 ? (event.riseTimeMs - meanRiseTime) / stdRiseTime : 0
        
        let zScore = (abs(zCrest) + abs(zRise)) / 2.0
        return max(0, 1.0 - zScore / 3.0)
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

    // MARK: Factory

    /// Fit a `CalibrationData` model from a non-empty array of tap events.
    static func fit(
        samples: [TapEvent],
        learnedDoubleTapWindowMs: Double? = nil,
        learnedTripleTapWindowMs: Double? = nil
    ) -> CalibrationData {
        precondition(!samples.isEmpty, "Cannot fit model from empty sample set")
        let crests = samples.map(\.crestFactor)
        let rises  = samples.map(\.riseTimeMs)
        let axisZs = samples.map(\.axisRatioZ)
        return CalibrationData(
            calibratedAt:             Date(),
            sampleCount:              samples.count,
            meanCrestFactor:          crests.statisticalMean,
            stdCrestFactor:           crests.standardDeviation,
            meanRiseTime:             rises.statisticalMean,
            stdRiseTime:              rises.standardDeviation,
            meanAxisZ:                axisZs.statisticalMean,
            stdAxisZ:                 axisZs.standardDeviation,
            learnedDoubleTapWindowMs: learnedDoubleTapWindowMs,
            learnedTripleTapWindowMs: learnedTripleTapWindowMs
        )
    }

    /// Bootstrap an initial model from a single event using a wide prior.
    static func bootstrap(from event: TapEvent) -> CalibrationData {
        CalibrationData(
            calibratedAt:             Date(),
            sampleCount:              1,
            meanCrestFactor:          event.crestFactor,
            stdCrestFactor:           0.5,    // wide prior
            meanRiseTime:             event.riseTimeMs,
            stdRiseTime:              10.0,   // wide prior
            meanAxisZ:                event.axisRatioZ,
            stdAxisZ:                 0.20,
            learnedDoubleTapWindowMs: nil,
            learnedTripleTapWindowMs: nil
        )
    }

    /// Returns a new model updated via Exponential Moving Average (α = 0.05).
    func updating(with event: TapEvent) -> CalibrationData {
        let α: Double = 0.05
        
        // Update Crest Factor
        let c = event.crestFactor
        let oldMeanCrest = meanCrestFactor
        let newMeanCrest = meanCrestFactor + α * (c - meanCrestFactor)
        let newVarCrest  = (1 - α) * (stdCrestFactor * stdCrestFactor + α * pow(c - oldMeanCrest, 2))

        // Update Rise Time
        let r = event.riseTimeMs
        let oldMeanRise = meanRiseTime
        let newMeanRise = meanRiseTime + α * (r - meanRiseTime)
        let newVarRise  = (1 - α) * (stdRiseTime * stdRiseTime + α * pow(r - oldMeanRise, 2))

        // Update Axis Z
        let axisZ = event.axisRatioZ
        let oldMeanZ = meanAxisZ
        let newMeanZ = meanAxisZ + α * (axisZ - meanAxisZ)
        let newVarZ  = (1 - α) * (stdAxisZ * stdAxisZ + α * pow(axisZ - oldMeanZ, 2))

        return CalibrationData(
            calibratedAt:             calibratedAt,
            sampleCount:              sampleCount + 1,
            meanCrestFactor:          newMeanCrest,
            stdCrestFactor:           sqrt(max(1e-6, newVarCrest)),
            meanRiseTime:             newMeanRise,
            stdRiseTime:              sqrt(max(1e-6, newVarRise)),
            meanAxisZ:                newMeanZ,
            stdAxisZ:                 sqrt(max(1e-6, newVarZ)),
            learnedDoubleTapWindowMs: learnedDoubleTapWindowMs,
            learnedTripleTapWindowMs: learnedTripleTapWindowMs
        )
    }
}

// MARK: - Array statistics helpers (private)

private extension [Double] {
    var statisticalMean: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
    var standardDeviation: Double {
        guard count > 1 else { return 0 }
        let m = statisticalMean
        let variance = map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count)
        return sqrt(variance)
    }
}
