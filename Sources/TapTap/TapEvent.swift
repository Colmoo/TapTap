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
        } else {
            return  // dimension mismatch — do not count toward activation
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
