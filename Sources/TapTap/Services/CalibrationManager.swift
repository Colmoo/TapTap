import Foundation
import Observation

/// Which side is currently being collected during side calibration.
enum SideCalibrationSide: Equatable {
    case left, right
}

/// Phase of a guided calibration session.
enum CalibrationPhase: Equatable {
    case idle
    case collectingSingle   // Phase 1: magnitude model (10 single taps)
    case collectingDouble   // Phase 2: double-tap timing (5 double-taps)
    case collectingTriple   // Phase 3: triple-tap timing (3 triple-taps)
    case complete
}

/// Collects `TapEvent`s during a guided calibration session, fits a Gaussian
/// model, and persists the result in `UserDefaults`.
///
/// **Typical flow:**
/// 1. Caller invokes `startCalibration()`.
/// 2. For each detected tap event, caller invokes `recordEvent(_:)`.
/// 3. The session progresses through three phases automatically:
///    - Phase 1 (10 single taps): fits the magnitude/axis Gaussian model.
///    - Phase 2 (5 double-taps): measures natural double-tap interval.
///    - Phase 3 (3 triple-taps): measures natural triple-tap interval.
/// 4. After all phases, `onCalibrationComplete` fires with the full model.
@Observable
@MainActor
final class CalibrationManager {

    // MARK: - Constants

    static let targetSampleCount       = 10   // single taps for magnitude model
    static let targetDoubleSampleCount = 5    // double-tap pairs for timing
    static let targetTripleSampleCount = 3    // triple-tap sequences for timing
    /// Minimum samples before the ML score gate activates.
    static let minSamplesForMLGate     = 5
    private static let persistenceKey  = "TapTap.calibration.v1"

    // MARK: - Observable state

    private(set) var phase: CalibrationPhase = .idle
    private(set) var collectedSamples: [TapEvent] = []
    private(set) var calibrationData: CalibrationData? = nil
    /// Magnitude of the most-recently recorded tap (drives live progress UI).
    private(set) var lastRecordedMagnitude: Double = 0
    /// Count of accepted real-world taps that have updated the model since launch.
    private(set) var learnedTapCount: Int = 0
    /// How many double-tap pairs have been collected in phase 2.
    private(set) var doubleSamplesCollected: Int = 0
    /// How many triple-tap sequences have been collected in phase 3.
    private(set) var tripleSamplesCollected: Int = 0

    // MARK: - Timing calibration state (private)

    private var doubleTapIntervals: [Double] = []  // ms between each pair
    private var tripleTapIntervals: [Double] = []  // max ms between consecutive taps in a triple
    private var timingLastTapDate: Date? = nil      // last tap date for double-tap pairing
    private var recentTripleTimes: [Date] = []     // recent tap dates for triple detection

    // MARK: - Callbacks

    /// Fired on the main actor after a new model is fully fitted and stored.
    var onCalibrationComplete: (() -> Void)?

    // MARK: - Computed

    var isCalibrating: Bool {
        phase == .collectingSingle || phase == .collectingDouble || phase == .collectingTriple
    }
    var isCalibrated: Bool   { calibrationData != nil }
    var collectedCount: Int  { collectedSamples.count }
    var remainingTaps: Int   { max(0, Self.targetSampleCount - collectedSamples.count) }
    var isMLReady: Bool      { (calibrationData?.sampleCount ?? 0) >= Self.minSamplesForMLGate }

    /// Overall 0–1 progress across all three phases.
    var progress: Double {
        switch phase {
        case .idle:             return 0
        case .collectingSingle: return Double(collectedSamples.count) / Double(Self.targetSampleCount) * 0.34
        case .collectingDouble: return 0.34 + Double(doubleSamplesCollected) / Double(Self.targetDoubleSampleCount) * 0.33
        case .collectingTriple: return 0.67 + Double(tripleSamplesCollected) / Double(Self.targetTripleSampleCount) * 0.33
        case .complete:         return 1.0
        }
    }

    // MARK: - Side calibration state (Step 10)

    private static let sidePersistenceKey = "TapTap.sideCalibration.v1"
    static let targetSideCount = 20  // taps per side

    private(set) var sideCalibrationData: SideCalibrationData? = nil
    private(set) var sidePhase: SideCalibrationSide? = nil  // nil = not calibrating
    private(set) var leftSideFeatures:  [[Double]] = []
    private(set) var rightSideFeatures: [[Double]] = []

    var isSideCalibrating: Bool { sidePhase != nil }
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

    // MARK: - Init

    init() { loadPersistedData() }

    // MARK: - Control

    func startCalibration() {
        collectedSamples        = []
        lastRecordedMagnitude   = 0
        learnedTapCount         = 0
        doubleTapIntervals      = []
        tripleTapIntervals      = []
        timingLastTapDate       = nil
        recentTripleTimes       = []
        doubleSamplesCollected  = 0
        tripleSamplesCollected  = 0
        phase                   = .collectingSingle
    }

    /// Feed a detected tap event into the active calibration phase.
    ///
    /// Does nothing when not calibrating.  Drives the phase state machine
    /// automatically: single → double → triple → complete.
    func recordEvent(_ event: TapEvent) {
        guard isCalibrating else { return }
        lastRecordedMagnitude = event.peakMagnitude

        switch phase {

        // ── Phase 1: magnitude model ─────────────────────────────────────
        case .collectingSingle:
            collectedSamples.append(event)
            if collectedSamples.count >= Self.targetSampleCount {
                // Fit and persist the magnitude model, then move to timing.
                let data = CalibrationData.fit(samples: collectedSamples)
                calibrationData = data
                persist(data)
                // Advance
                phase                   = .collectingDouble
                timingLastTapDate       = nil
                doubleTapIntervals      = []
                doubleSamplesCollected  = 0
            }

        // ── Phase 2: double-tap timing ───────────────────────────────────
        case .collectingDouble:
            let now = event.timestamp
            if let last = timingLastTapDate,
               now.timeIntervalSince(last) < 1.2 {
                // Second tap of a pair — record the gap.
                doubleTapIntervals.append(now.timeIntervalSince(last) * 1_000)
                doubleSamplesCollected += 1
                timingLastTapDate = nil
                if doubleSamplesCollected >= Self.targetDoubleSampleCount {
                    // Advance to triple timing.
                    phase               = .collectingTriple
                    recentTripleTimes   = []
                    tripleTapIntervals  = []
                    tripleSamplesCollected = 0
                }
            } else {
                // First tap of a new pair (or gap too long — treat as reset).
                timingLastTapDate = now
            }

        // ── Phase 3: triple-tap timing ───────────────────────────────────
        case .collectingTriple:
            let now = event.timestamp
            // Drop any taps older than 2.5 s so stray singles don't accumulate.
            recentTripleTimes = recentTripleTimes.filter { now.timeIntervalSince($0) < 2.5 }
            recentTripleTimes.append(now)

            if recentTripleTimes.count >= 3 {
                // Got a complete triple — measure the worst-case gap.
                let i1 = recentTripleTimes[1].timeIntervalSince(recentTripleTimes[0]) * 1_000
                let i2 = recentTripleTimes[2].timeIntervalSince(recentTripleTimes[1]) * 1_000
                tripleTapIntervals.append(max(i1, i2))
                tripleSamplesCollected += 1
                recentTripleTimes = []
                if tripleSamplesCollected >= Self.targetTripleSampleCount {
                    finalize()
                }
            }

        default:
            break
        }
    }

    /// Abort an in-progress calibration without fitting a model.
    func cancel() {
        collectedSamples        = []
        doubleTapIntervals      = []
        tripleTapIntervals      = []
        timingLastTapDate       = nil
        recentTripleTimes       = []
        doubleSamplesCollected  = 0
        tripleSamplesCollected  = 0
        phase                   = .idle
    }

    /// Discard all calibration data and revert to manual threshold sliders.
    func reset() {
        collectedSamples        = []
        calibrationData         = nil
        learnedTapCount         = 0
        doubleTapIntervals      = []
        tripleTapIntervals      = []
        timingLastTapDate       = nil
        recentTripleTimes       = []
        doubleSamplesCollected  = 0
        tripleSamplesCollected  = 0
        phase                   = .idle
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
    }

    // MARK: - Side calibration (Step 10)

    func startSideCalibration() {
        leftSideFeatures  = []
        rightSideFeatures = []
        sidePhase         = .left
    }

    /// Record a labelled feature vector during side calibration.
    /// Call this from the same tap-event path, gated by `isSideCalibrating`.
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

    func cancelSideCalibration() {
        leftSideFeatures  = []
        rightSideFeatures = []
        sidePhase         = nil
    }

    func resetSideCalibration() {
        cancelSideCalibration()
        sideCalibrationData = nil
        UserDefaults.standard.removeObject(forKey: Self.sidePersistenceKey)
    }

    private func finalizeSideCalibration() {
        guard let data = SideCalibrationData.fit(
            leftSamples: leftSideFeatures,
            rightSamples: rightSideFeatures
        ) else { return }
        sideCalibrationData = data
        sidePhase           = nil
        persistSideData(data)
    }

    private func persistSideData(_ data: SideCalibrationData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.sidePersistenceKey)
    }

    // MARK: - Online learning

    func recordAcceptedTap(_ event: TapEvent) {
        guard !isCalibrating else { return }

        let updated: CalibrationData
        if let existing = calibrationData {
            updated = existing.updating(with: event)
        } else {
            updated = CalibrationData.bootstrap(from: event)
        }

        calibrationData = updated
        learnedTapCount += 1
        persist(updated)
    }

    // MARK: - Private

    /// Complete the calibration session: merge timing into the magnitude model,
    /// persist, and fire the completion callback.
    private func finalize() {
        guard let existing = calibrationData else { return }

        let learnedDouble = computeWindow(
            from: doubleTapIntervals,
            defaultMs: 300, minMs: 200, maxMs: 800
        )
        let learnedTriple = computeWindow(
            from: tripleTapIntervals,
            defaultMs: 500, minMs: 300, maxMs: 1_200
        )

        let data = CalibrationData(
            calibratedAt:             existing.calibratedAt,
            sampleCount:              existing.sampleCount,
            meanCrestFactor:          existing.meanCrestFactor,
            stdCrestFactor:           existing.stdCrestFactor,
            meanRiseTime:             existing.meanRiseTime,
            stdRiseTime:              existing.stdRiseTime,
            meanAxisZ:                existing.meanAxisZ,
            stdAxisZ:                 existing.stdAxisZ,
            learnedDoubleTapWindowMs: learnedDouble,
            learnedTripleTapWindowMs: learnedTriple
        )

        calibrationData = data
        phase           = .complete
        persist(data)
        onCalibrationComplete?()
    }

    /// Derives a debounce window from a set of measured inter-tap intervals.
    /// Window = mean + 2σ + 50 ms buffer, clamped to [minMs, maxMs].
    private func computeWindow(from intervals: [Double], defaultMs: Double, minMs: Double, maxMs: Double) -> Double {
        guard !intervals.isEmpty else { return defaultMs }
        let n    = Double(intervals.count)
        let mean = intervals.reduce(0, +) / n
        let std  = sqrt(intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n)
        return min(maxMs, max(minMs, mean + 2 * std + 50))
    }

    private func persist(_ data: CalibrationData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.persistenceKey)
    }

    private func loadPersistedData() {
        if let raw  = UserDefaults.standard.data(forKey: Self.persistenceKey),
           let data = try? JSONDecoder().decode(CalibrationData.self, from: raw) {
            calibrationData = data
            phase           = .complete
        }
        if let raw  = UserDefaults.standard.data(forKey: Self.sidePersistenceKey),
           let data = try? JSONDecoder().decode(SideCalibrationData.self, from: raw) {
            sideCalibrationData = data
        }
    }
}
