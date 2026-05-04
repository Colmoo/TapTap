import Foundation
import TapTapC

/// Reads accelerometer and gyroscope data from the built-in IMU via IOKit HID
/// and emits a `TapEvent` when the acceleration magnitude crosses `tapThresholdG`.
///
/// ## Pipeline (Steps 1–9)
///
/// 1. **Differentiate** — every accel/gyro sample is converted to its first
///    derivative (Δ per sample) to remove DC bias and normalise scale.
/// 2. **Circular buffer** — differentiated 6-channel samples are written to a
///    ring buffer, providing ~30 ms of pre-peak history.
/// 3. **Gyro energy gate (Step 2)** — tracks summed gyro energy during the
///    window; rejects the event if below `gyroEnergyGateThreshold` (default 0).
/// 4. **Peak-tracking window** — on threshold crossing, a window opens and
///    tracks the maximum magnitude and axis components.
/// 5. **Peak-valley check (Step 3)** — at window close, verifies the
///    differentiated z-axis shows a physical rebound valley (optional).
/// 6. **Aligned window extraction (Step 4)** — extracts a 120 ms window
///    (30 ms pre-peak + 90 ms post-peak) from the ring buffer.
/// 7. **Feature computation (Steps 5–9)** — rise time, FWHM, cross-axis
///    Pearson correlations, rotational impulse, channel energy, spectral bands.
/// 8. **Movement filter** — at window close, high sustained gyro magnitude
///    indicates whole-laptop movement; the event is rejected.
@MainActor
final class TapInputService {

    // MARK: - Callbacks

    var onTapEvent:           ((TapEvent) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?
    /// Fired when an event is rejected by the gyro movement filter.
    var onMovementRejected:   ((_ gyroMag: Double, _ threshold: Double) -> Void)?
    /// Fired when a tap crosses the threshold but is silently dropped before reaching onTapEvent.
    var onTapFiltered:        ((_ reason: String) -> Void)?
    /// Fired ~once per second with (magnitude, threshold) for liveness logging.
    var onDiagnosticSample:   ((Double, Double) -> Void)?

    // MARK: - Settings

    var tapThresholdG:              Double = 1.3
    var peakCooldownMs:             Double = 50
    var trackingWindowMs:           Double = 120   // extended to capture 90 ms post-peak
    var movementGyroThresholdRadS:  Double = 0.5
    /// Step 2: minimum Σ(ωx²+ωy²+ωz²) accumulated during the window.  0 = off.
    var gyroEnergyGateThreshold:    Double = 0.0
    /// Step 3: require a rebound valley in the differentiated z signal.
    var peakValleyCheckEnabled:     Bool   = false

    // MARK: - Public state

    private(set) var isRunning                 = false
    private(set) var isAccelerometerAvailable  = false
    private(set) var isGyroscopeAvailable      = false

    // MARK: - Step 1: Differentiation state

    private var prevAX: Double = 0, prevAY: Double = 0, prevAZ: Double = 0
    private var prevGX: Double = 0, prevGY: Double = 0, prevGZ: Double = 0

    // MARK: - Gyro state

    private var latestGX: Double = 0, latestGY: Double = 0, latestGZ: Double = 0
    /// Most recent differentiated gyro (used when building each ring-buffer entry).
    private var latestDGX: Double = 0, latestDGY: Double = 0, latestDGZ: Double = 0
    /// Most recent gyro magnitude (used by the closing movement filter).
    private var latestGyroMag: Double = 0

    // MARK: - Step 2/4: Circular buffer

    private static let sampleRate: Double = 200.0   // IMU poll rate (Hz)
    /// 3 s of history at 200 Hz — plenty for any window we'll ever need.
    private let imuBuf = IMUCircularBuffer(capacity: 600)

    // MARK: - Tracking state

    private var lastPeakDate:      Date = .distantPast
    private var isTracking:        Bool = false
    private var trackingStart:     Date = .distantPast
    private var trackingPeakDate:  Date = .distantPast
    private var trackingSamples:   [Double] = []    // magnitudes during window
    private var trackingWork:      DispatchWorkItem?
    private var trackingPeakMag:   Double = 0
    private var trackingPeakX:     Double = 0
    private var trackingPeakY:     Double = 0
    private var trackingPeakZ:     Double = 0
    /// Ring-buffer write index when the magnitude peak was first seen.
    private var trackingPeakBufIdx: Int = 0
    /// Step 2: accumulated raw gyro energy during the window.
    private var trackingGyroEnergy: Double = 0
    private var sampleCount: Int = 0

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let gyroCtx = Unmanaged.passUnretained(self).toOpaque()
        let gyroRet = tap_gyro_start({ rx, ry, rz, ctxPtr in
            guard let ctxPtr else { return }
            let svc = Unmanaged<TapInputService>.fromOpaque(ctxPtr).takeUnretainedValue()
            svc.handleGyroSample(rx: rx, ry: ry, rz: rz)
        }, gyroCtx)
        isGyroscopeAvailable = (gyroRet == 0)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let ret = tap_accel_start({ x, y, z, ctxPtr in
            guard let ctxPtr else { return }
            let svc = Unmanaged<TapInputService>.fromOpaque(ctxPtr).takeUnretainedValue()
            svc.handleSample(x: x, y: y, z: z)
        }, ctx)
        setAvailable(ret == 0)
    }

    func stop() {
        tap_gyro_stop()
        tap_accel_stop()
        trackingWork?.cancel()
        trackingWork  = nil
        isTracking    = false
        isRunning     = false
        latestGyroMag = 0
        setAvailable(false)
    }

    // MARK: - Sample processing

    // nonisolated: C callbacks can't carry actor context.
    // CFRunLoopGetMain() guarantees execution on the main thread, so the
    // Task hop into @MainActor is safe.
    nonisolated func handleSample(x: Double, y: Double, z: Double) {
        Task { @MainActor [weak self] in
            self?.processAccelSample(x: x, y: y, z: z)
        }
    }

    nonisolated func handleGyroSample(rx: Double, ry: Double, rz: Double) {
        Task { @MainActor [weak self] in
            self?.processGyroSample(rx: rx, ry: ry, rz: rz)
        }
    }

    // MARK: - @MainActor sample handlers

    private func processAccelSample(x: Double, y: Double, z: Double) {
        // Step 1: differentiate
        let dax = x - prevAX; let day = y - prevAY; let daz = z - prevAZ
        prevAX = x; prevAY = y; prevAZ = z

        // Step 4: push to ring buffer (pair with latest gyro differential)
        imuBuf.append(IMUSample(dax: dax, day: day, daz: daz,
                                dgx: latestDGX, dgy: latestDGY, dgz: latestDGZ))

        let magnitude = (x*x + y*y + z*z).squareRoot()

        sampleCount += 1
        if sampleCount % 200 == 0 {
            onDiagnosticSample?(magnitude, tapThresholdG)
        }

        if isTracking {
            trackingSamples.append(magnitude)
            if magnitude > trackingPeakMag {
                trackingPeakMag   = magnitude
                trackingPeakDate  = Date()
                trackingPeakX     = x
                trackingPeakY     = y
                trackingPeakZ     = z
                trackingPeakBufIdx = imuBuf.writeCount  // record position at peak
            }
        } else if magnitude > tapThresholdG {
            let now     = Date()
            let elapsed = now.timeIntervalSince(lastPeakDate) * 1_000
            guard elapsed > peakCooldownMs else { return }

            // Open tracking window
            lastPeakDate       = now
            isTracking         = true
            trackingStart      = now
            trackingPeakMag    = magnitude
            trackingPeakDate   = now
            trackingSamples    = [magnitude]
            trackingPeakX      = x
            trackingPeakY      = y
            trackingPeakZ      = z
            trackingPeakBufIdx  = imuBuf.writeCount
            trackingGyroEnergy = 0

            let work = DispatchWorkItem { [weak self] in
                self?.closeTrackingWindow()
            }
            trackingWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + trackingWindowMs / 1_000,
                execute: work
            )
        }
    }

    private func processGyroSample(rx: Double, ry: Double, rz: Double) {
        // Step 1: differentiate gyro
        latestDGX = rx - prevGX; latestDGY = ry - prevGY; latestDGZ = rz - prevGZ
        prevGX = rx; prevGY = ry; prevGZ = rz

        latestGX = rx; latestGY = ry; latestGZ = rz
        latestGyroMag = (rx*rx + ry*ry + rz*rz).squareRoot()

        // Step 2: accumulate raw gyro energy during tracking window
        if isTracking {
            trackingGyroEnergy += rx*rx + ry*ry + rz*rz
        }
    }

    // MARK: - Window close

    private func closeTrackingWindow() {
        let closingGyro = latestGyroMag
        let threshold   = movementGyroThresholdRadS
        isTracking      = false

        // Movement filter — high sustained gyro at window close = whole-device movement
        let isMovement = isGyroscopeAvailable && threshold > 0 && closingGyro > threshold
        if isMovement {
            onMovementRejected?(closingGyro, threshold)
            return
        }

        // Step 2: gyro energy gate
        if isGyroscopeAvailable && gyroEnergyGateThreshold > 0 &&
           trackingGyroEnergy < gyroEnergyGateThreshold {
            onTapFiltered?(String(format: "Gyro energy gate: %.4f < threshold %.4f", trackingGyroEnergy, gyroEnergyGateThreshold))
            return
        }

        // Compute classic shape features from magnitude window
        let rms         = sqrt(trackingSamples.map { $0 * $0 }.reduce(0, +) /
                               max(1.0, Double(trackingSamples.count)))
        let crestFactor = trackingPeakMag / max(0.01, rms)
        let riseTimeMs  = trackingPeakDate.timeIntervalSince(trackingStart) * 1_000

        // Steps 4–9: extract aligned window and compute feature vector
        let sr          = Self.sampleRate
        let preSamples  = Int(0.030 * sr)            // 6 samples pre-peak
        let peakAgo     = imuBuf.writeCount - trackingPeakBufIdx
        let windowStart = trackingPeakBufIdx - preSamples
        let windowCount = preSamples + max(peakAgo, Int(0.090 * sr))
        let raw         = imuBuf.slice(from: windowStart, count: windowCount)

        var tapFeatures: TapFeatureVector? = nil

        if raw.count >= 4 {
            let dax = raw.map(\.dax), day = raw.map(\.day), daz = raw.map(\.daz)
            let dgx = raw.map(\.dgx), dgy = raw.map(\.dgy), dgz = raw.map(\.dgz)

            // Find actual daz peak index (may differ slightly from magnitude peak)
            let peakIdx = daz.indices.max(by: { abs(daz[$0]) < abs(daz[$1]) })
                          ?? min(preSamples, raw.count - 1)

            let window = TapWindow(
                dax: dax, day: day, daz: daz,
                dgx: dgx, dgy: dgy, dgz: dgz,
                peakIdx: peakIdx,
                sampleRate: sr
            )

            // Step 3: peak-valley rebound check (optional gate)
            if peakValleyCheckEnabled && !hasValidRebound(daz: daz, peakIdx: peakIdx, sr: sr) {
                onTapFiltered?("Peak-valley check: no valid rebound detected")
                return
            }

            tapFeatures = window.featureVector()
        }

        // STA/LTA energy ratio — detects soft taps independently of calibration.
        // STA: 3 samples (~15 ms) starting at peak.
        // LTA: 100 samples (~500 ms) ending 1 sample before peak (no contamination).
        let staLtaScore: Double = {
            let staCount  = max(1, Int(0.015 * sr))   // 3 samples
            let ltaCount  = Int(0.500 * sr)            // 100 samples
            let staSamples = imuBuf.slice(from: trackingPeakBufIdx - staCount / 2, count: staCount)
            let ltaSamples = imuBuf.slice(from: trackingPeakBufIdx - ltaCount - 2, count: ltaCount)
            guard !staSamples.isEmpty, ltaSamples.count >= ltaCount / 2 else { return 0.0 }
            let staMean = staSamples.map { $0.dax*$0.dax + $0.day*$0.day + $0.daz*$0.daz }.reduce(0, +) / Double(staSamples.count)
            let ltaMean = ltaSamples.map { $0.dax*$0.dax + $0.day*$0.day + $0.daz*$0.daz }.reduce(0, +) / Double(ltaSamples.count)
            guard ltaMean > 1e-12 else { return 0.0 }
            return min(1.0, max(0.0, (staMean / ltaMean - 1.0) / 9.0))
        }()

        var event = TapEvent(
            timestamp:            trackingStart,
            peakMagnitude:        trackingPeakMag,
            peakX:                trackingPeakX,
            peakY:                trackingPeakY,
            peakZ:                trackingPeakZ,
            closingGyroMagnitude: closingGyro,
            crestFactor:          crestFactor,
            riseTimeMs:           riseTimeMs,
            features:             tapFeatures
        )
        event.staLtaScore = staLtaScore
        onTapEvent?(event)
    }

    // MARK: - Step 3: Peak-valley rebound check

    private func hasValidRebound(daz: [Double], peakIdx: Int, sr: Double) -> Bool {
        let lookAhead = min(peakIdx + Int(0.030 * sr), daz.count - 1)
        guard lookAhead > peakIdx else { return false }
        let postPeak = Array(daz[peakIdx...lookAhead])
        guard let valley = postPeak.min() else { return false }
        let peak = daz[peakIdx]
        guard abs(peak) > 1e-9 else { return false }
        let ratio = abs(valley / peak)
        return ratio > 0.15 && ratio < 0.95
    }

    // MARK: - Availability

    private func setAvailable(_ value: Bool) {
        guard isAccelerometerAvailable != value else { return }
        isAccelerometerAvailable = value
        onAvailabilityChanged?(value)
    }
}
