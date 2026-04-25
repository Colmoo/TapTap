import AVFoundation
import Foundation

/// Detects taps acoustically via the MacBook's built-in stereo microphones and
/// classifies each event as left / centre / right using Time Difference of Arrival (TDOA).
///
/// Approach (derived from SurfaceTap — https://github.com/kdv123/SurfaceTap):
///  1. Capture stereo PCM at the native input rate (typically 48 kHz).
///  2. Apply a 1st-order IIR high-pass filter (~150 Hz cutoff) to strip low-frequency
///     rumble and preserve the sharp transient of a chassis tap.
///  3. Find the first sample in each channel that exceeds `noiseFloor × thresholdMultiplier`.
///  4. Compute TDOA = (first-crossing index in L) − (first-crossing index in R).
///     Positive → left arrived first → left tap; negative → right tap.
///     |TDOA| below `sideThresholdMs` is classified as centre.
///
/// Physical basis: MacBook keyboard width ≈ 28 cm, speed of sound ≈ 343 m/s,
/// so max TDOA ≈ 0.82 ms (≈ 39 samples at 48 kHz). Crossing-sample resolution is
/// therefore adequate for reliable left/right separation.
///
/// The most recent detection is stored in `lastDetectionSide` / `lastDetectionDate`
/// so that `AppEnvironment` can correlate it with an IMU tap event.
@MainActor
final class MicInputService {

    // MARK: - Callbacks

    /// Fired on each detected tap with the classified side.
    var onTap: ((TapSide) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?
    /// Fired on each acoustic transient with side and peak amplitude (0–1).
    /// Used by the debug UI to show a live acoustic-activity indicator.
    var onAcousticTap: ((TapSide, Float) -> Void)?

    // MARK: - Public read-only state

    /// Peak amplitude of the most-recently detected acoustic transient.
    private(set) var lastAcousticPeak: Float = 0

    // MARK: - Settings (push via AppEnvironment.applySettings)

    var thresholdMultiplier: Double = 6.0   // noise floor × this = detection threshold
    var sideThresholdMs: Double     = 0.2   // |TDOA| below this → .center
    var peakCooldownMs: Double      = 100   // minimum ms between tap events

    // MARK: - Public state

    private(set) var isRunning: Bool   = false
    private(set) var isAvailable: Bool = false

    /// Timestamp and side of the most recent mic detection.
    private(set) var lastDetectionDate: Date    = .distantPast
    private(set) var lastDetectionSide: TapSide = .center

    // MARK: - Private audio state

    private var engine: AVAudioEngine?
    private var sampleRate: Double = 48_000

    // 1st-order IIR high-pass filter state (per channel: 0 = left, 1 = right).
    // y[n] = α · (y[n-1] + x[n] − x[n-1]),  α = τ/(τ+T), τ = 1/(2π·150 Hz)
    private var filterAlpha: Float = 0.9806
    private var filterPrevX: [Float] = [0, 0]
    private var filterPrevY: [Float] = [0, 0]

    // Rolling noise floor: minimum RMS across recent quiet buffers, per channel.
    private var noiseFloor: [Float]         = [0.001, 0.001]
    private var quietRmsHistory: [[Float]]  = [[], []]
    private let noiseWindowCount            = 100   // buffers (≈ 1 s at 512-sample chunks)

    // Cooldown tracking.
    private var lastTapDate: Date = .distantPast

    // Acoustic transient history for IMU correlation.
    // Each entry records the wall-clock time and side of a detected transient.
    // Kept trimmed to `maxTransientHistory` entries so memory is bounded.
    private var transientHistory: [(date: Date, side: TapSide)] = []
    private let maxTransientHistory = 30

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.startEngine()
                } else {
                    self.setAvailable(false)
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        filterPrevX = [0, 0]
        filterPrevY = [0, 0]
        noiseFloor = [0.001, 0.001]
        quietRmsHistory = [[], []]
        setAvailable(false)
    }

    // MARK: - Correlation helpers

    /// Returns the side from the most recent detection if it occurred after `since`.
    func recentSide(since: Date) -> TapSide {
        lastDetectionDate > since ? lastDetectionSide : .center
    }

    /// Returns the most recent acoustic transient whose timestamp falls within
    /// `±windowSec` of `date`, or `nil` if none exists in that window.
    ///
    /// Used by `AppEnvironment` to confirm that an IMU-detected tap event has a
    /// matching acoustic counterpart from the microphone.
    ///
    /// - Parameters:
    ///   - date:      The reference timestamp (typically `TapEvent.timestamp`).
    ///   - windowSec: Half-width of the correlation window in seconds.
    ///                Genuine taps typically land within 10–20 ms; 30 ms default
    ///                provides comfortable headroom without catching unrelated sounds.
    func transient(near date: Date, windowSec: Double = 0.030) -> (date: Date, side: TapSide)? {
        let lo = date.addingTimeInterval(-windowSec)
        let hi = date.addingTimeInterval(+windowSec)
        return transientHistory.last { $0.date >= lo && $0.date <= hi }
    }

    // MARK: - Private

    private func startEngine() {
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let fmt = inputNode.inputFormat(forBus: 0)
        sampleRate = fmt.sampleRate

        // Recompute filter alpha for the actual sample rate.
        let tau = 1.0 / (2.0 * Double.pi * 150.0)   // τ = 1/(2π·fc)
        let T   = 1.0 / sampleRate
        filterAlpha = Float(tau / (tau + T))

        // Build the tap block in a nonisolated context so Swift does NOT infer it as
        // @MainActor-isolated.  A closure defined inside a @MainActor method inherits
        // that isolation automatically — even without a self capture — which makes
        // AVAudioEngine crash with dispatch_assert_queue when it calls the tap from the
        // CoreAudio real-time thread.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: fmt, block: makeTapBlock())

        do {
            try eng.start()
            engine   = eng
            isRunning = true
            setAvailable(true)
        } catch {
            setAvailable(false)
        }
    }

    // Returns a tap block that is NOT @MainActor-isolated. Creating the closure inside a
    // `nonisolated` method breaks the automatic isolation inference that would otherwise
    // mark it as @MainActor (because it is defined in a @MainActor class).
    //
    // The block copies samples synchronously on the CoreAudio real-time thread — which is
    // safe because it touches no actor state — then hops to @MainActor via a Task.
    nonisolated private func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount   = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            let left  = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let right = channelCount > 1
                ? Array(UnsafeBufferPointer(start: channelData[1], count: frameCount))
                : left
            Task { @MainActor [weak self] in
                self?.processBuffer(left: left, right: right)
            }
        }
    }

    private func processBuffer(left: [Float], right: [Float]) {
        let n = left.count
        var filtL = [Float](repeating: 0, count: n)
        var filtR = [Float](repeating: 0, count: n)

        // --- High-pass filter ---
        for i in 0..<n {
            filtL[i] = filterAlpha * (filterPrevY[0] + left[i]  - filterPrevX[0])
            filterPrevX[0] = left[i];  filterPrevY[0] = filtL[i]
            filtR[i] = filterAlpha * (filterPrevY[1] + right[i] - filterPrevX[1])
            filterPrevX[1] = right[i]; filterPrevY[1] = filtR[i]
        }

        // --- Cooldown gate ---
        let now = Date()
        guard now.timeIntervalSince(lastTapDate) * 1000 > peakCooldownMs else { return }

        let threshL = noiseFloor[0] * Float(thresholdMultiplier)
        let threshR = noiseFloor[1] * Float(thresholdMultiplier)

        // --- Find first threshold crossing per channel ---
        var crossL = -1, crossR = -1
        for i in 0..<n {
            if crossL < 0 && abs(filtL[i]) > threshL { crossL = i }
            if crossR < 0 && abs(filtR[i]) > threshR { crossR = i }
            if crossL >= 0 && crossR >= 0 { break }
        }

        let anyActivity = crossL >= 0 || crossR >= 0

        if anyActivity {
            // --- Classify side from TDOA ---
            let side: TapSide
            if crossL < 0 {
                // Only right channel triggered → right-side tap
                side = .right
            } else if crossR < 0 {
                // Only left channel triggered → left-side tap
                side = .left
            } else {
                // Both channels triggered — compute TDOA in ms
                let tdoaMs = Double(crossL - crossR) / (sampleRate / 1000.0)
                if abs(tdoaMs) < sideThresholdMs {
                    side = .center
                } else {
                    side = tdoaMs > 0 ? .left : .right
                }
            }

            lastTapDate        = now
            lastDetectionDate  = now
            lastDetectionSide  = side

            // Record into transient history for IMU correlation.
            let peakL = crossL >= 0 ? abs(filtL[crossL]) : 0
            let peakR = crossR >= 0 ? abs(filtR[crossR]) : 0
            let peakAmp = max(peakL, peakR)
            lastAcousticPeak = peakAmp
            transientHistory.append((date: now, side: side))
            if transientHistory.count > maxTransientHistory {
                transientHistory.removeFirst()
            }

            onTap?(side)
            onAcousticTap?(side, peakAmp)

        } else {
            // --- Quiet buffer — update rolling noise floor ---
            let rmsL = rms(filtL), rmsR = rms(filtR)
            quietRmsHistory[0].append(rmsL)
            quietRmsHistory[1].append(rmsR)
            if quietRmsHistory[0].count > noiseWindowCount { quietRmsHistory[0].removeFirst() }
            if quietRmsHistory[1].count > noiseWindowCount { quietRmsHistory[1].removeFirst() }
            if quietRmsHistory[0].count >= 5 {
                noiseFloor[0] = max(quietRmsHistory[0].min() ?? 0.001, 0.0001)
                noiseFloor[1] = max(quietRmsHistory[1].min() ?? 0.001, 0.0001)
            }
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private func setAvailable(_ value: Bool) {
        guard isAvailable != value else { return }
        isAvailable = value
        onAvailabilityChanged?(value)
    }
}
