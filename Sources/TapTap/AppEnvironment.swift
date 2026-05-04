import Foundation
import Observation
import ServiceManagement

/// Single object passed through the SwiftUI environment. Owns all services
/// and wires the tap-input → classifier → executor pipeline.
@Observable
@MainActor
final class AppEnvironment {
    let store = BindingStore()
    let logger = EventLogger()
    let permissions = PermissionManager()
    let calibration = CalibrationManager()

    private let input = TapInputService()
    private let mic = MicInputService()
    private let classifier = GestureClassifier()
    private let executor = ActionExecutor()

    /// Timestamp of the most recent gyro-rejected movement event.
    /// Online learning is frozen for 2 s after any movement detection so
    /// settling vibrations cannot corrupt the calibration model.
    private var lastMovementTime: Date = .distantPast

    /// Passive noise model — populated from strongly-rejected IMU events.
    private(set) var noiseModel: NoiseModel = .empty

    private(set) var isListening: Bool = false
    private(set) var lastGesture: GestureType? = nil
    /// Increments with every gesture detection. Use this in onChange to guarantee
    /// the handler fires even when the same gesture fires twice in a row.
    private(set) var gestureDetectionCount: Int = 0
    private(set) var isAccelerometerAvailable: Bool = false
    private(set) var isGyroscopeAvailable: Bool = false
    private(set) var isMicAvailable: Bool = false
    /// Most recent raw tap event from the IMU (updated even during calibration).
    private(set) var lastTapEvent: TapEvent? = nil
    /// ML match score for the most recent tap event (nil when ML is not active).
    private(set) var lastTapScore: Double? = nil
    /// Peak amplitude of the most-recently detected acoustic transient (0–1).
    /// Drives the live acoustic-activity pulse in DetectionView.
    private(set) var lastAcousticPeak: Float = 0

    init() {
        applySettings()
        wireUpPipeline()
        loadNoiseModel()
        startListening()
    }

    // MARK: - Control

    func startListening() {
        input.start()
        isListening = input.isRunning
        isGyroscopeAvailable = input.isGyroscopeAvailable
        if isListening {
            logger.log(String(format: "Listening started (threshold %.3f g)", store.settings.tapThresholdG), kind: .system)
        }
        if store.settings.micEnabled {
            mic.start()
        }
    }

    func stopListening() {
        input.stop()
        mic.stop()
        isListening = false
        logger.log("Listening stopped", kind: .system)
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    // MARK: - Noise model persistence

    private func loadNoiseModel() {
        guard let raw  = UserDefaults.standard.data(forKey: NoiseModel.persistenceKey),
              let model = try? JSONDecoder().decode(NoiseModel.self, from: raw) else { return }
        noiseModel = model
    }

    private func persistNoiseModel() {
        guard let data = try? JSONEncoder().encode(noiseModel) else { return }
        UserDefaults.standard.set(data, forKey: NoiseModel.persistenceKey)
    }

    func resetNoiseModel() {
        noiseModel = .empty
        UserDefaults.standard.removeObject(forKey: NoiseModel.persistenceKey)
    }

    /// Inject a synthetic tap — useful for testing without real hardware.
    func simulateTap() {
        classifier.registerTap()
    }

    /// Manually trigger a binding's action for testing.
    func testAction(binding: GestureBinding) {
        Task {
            await executor.testAction(binding, logger: logger)
        }
    }

    /// Re-read settings from the store and push them into the services.
    func applySettings() {
        let s = store.settings
        classifier.doubleTapWindow = s.doubleTapWindowMs / 1000
        classifier.tripleTapWindow = s.tripleTapWindowMs / 1000
        classifier.cooldown = s.globalCooldownMs / 1000
        input.tapThresholdG              = s.tapThresholdG
        input.peakCooldownMs             = s.tapPeakCooldownMs
        input.movementGyroThresholdRadS  = s.movementGyroThresholdRadS
        input.gyroEnergyGateThreshold    = s.gyroEnergyGateThreshold
        input.peakValleyCheckEnabled     = s.peakValleyCheckEnabled
        mic.thresholdMultiplier = s.micThresholdMultiplier
        mic.sideThresholdMs     = s.micSideThresholdMs
        // Start or stop mic to match the toggled setting while listening.
        if isListening {
            if s.micEnabled && !mic.isRunning { mic.start() }
            if !s.micEnabled && mic.isRunning { mic.stop() }
        }

        // Apply launch at login setting
        do {
            let status = SMAppService.mainApp.status
            if s.launchAtLogin && status == .notRegistered {
                try SMAppService.mainApp.register()
                logger.log("Registered for Launch at Login", kind: .system)
            } else if !s.launchAtLogin && (status == .enabled || status == .requiresApproval) {
                try SMAppService.mainApp.unregister()
                logger.log("Unregistered from Launch at Login", kind: .system)
            }
        } catch {
            logger.log("Failed to configure Launch at Login: \(error.localizedDescription)", kind: .error)
        }
    }

    /// Returns the ML gate threshold to compare final scores against.
    /// Uses calibration floor × 0.85 + sensitivity bias unless the user manually overrode it.
    private func effectiveMLThreshold(for data: CalibrationData) -> Double {
        let s = store.settings
        if s.userOverrodeMLThreshold { return s.mlScoreThreshold }
        let auto = data.calibrationFloorScore * 0.5
        return min(0.99, max(0.01, auto + s.sensitivityBias * 0.15))
    }

    // MARK: - Pipeline

    private func wireUpPipeline() {
        // Hook: calibration completion → auto-apply threshold + learned timing windows
        calibration.onCalibrationComplete = { [weak self] in
            guard let self, let data = self.calibration.calibrationData else { return }
            var s = self.store.settings
            if let doubleMs = data.learnedDoubleTapWindowMs {
                s.doubleTapWindowMs = doubleMs
            }
            if let tripleMs = data.learnedTripleTapWindowMs {
                s.tripleTapWindowMs = tripleMs
            }
            s.userOverrodeMLThreshold = false   // re-enable auto-threshold after recalibration
            self.store.update(settings: s)
            self.applySettings()

            var msg = String(format: "Calibration complete — (grade %@)", data.qualityGrade)
            if let d = data.learnedDoubleTapWindowMs, let t = data.learnedTripleTapWindowMs {
                msg += String(format: ", double-tap %.0f ms, triple-tap %.0f ms", d, t)
            }
            self.logger.log(msg, kind: .system)
        }

        input.onTapEvent = { [weak self] event in
            guard let self else { return }
            self.lastTapEvent = event

            if self.store.settings.debugLoggingEnabled {
                self.logger.log(
                    String(format: "Raw tap: %.3fg  sta=%.2f", event.peakMagnitude, event.staLtaScore),
                    kind: .system
                )
            }

            // During a guided calibration session: record the tap and skip classification.
            if self.calibration.isCalibrating {
                self.calibration.recordEvent(event)
                return
            }

            // During side calibration: collect labelled feature vectors.
            if self.calibration.isSideCalibrating {
                if let features = event.features {
                    self.calibration.recordSideTap(features: features)
                }
                return
            }

            // ML gate
            if self.store.settings.mlEnabled,
               self.calibration.isMLReady,
               let data = self.calibration.calibrationData {

                let s        = self.store.settings
                let mlScore  = data.matchScore(for: event)
                let staScore = s.staLtaEnabled ? event.staLtaScore : 0.0
                let blended  = max(mlScore, staScore)

                // Apply likelihood ratio when noise model is active
                let finalScore: Double
                if s.noiseModelEnabled, self.noiseModel.isActive,
                   let fv = event.features?.toArray() {
                    let noiseScore = self.noiseModel.score(for: fv)
                    finalScore = self.noiseModel.finalScore(tapScore: blended, noiseScore: noiseScore)
                } else {
                    finalScore = blended
                }
                self.lastTapScore = finalScore

                let threshold = self.effectiveMLThreshold(for: data)
                guard finalScore >= threshold else {
                    // Feed noise model only from events the ML scorer rejects strongly.
                    // Events that pass via STA/LTA but have low mlScore are real taps — skip.
                    if s.noiseModelEnabled,
                       mlScore < 0.10,
                       let fv = event.features?.toArray() {
                        self.noiseModel.update(features: fv)
                        self.persistNoiseModel()
                    }
                    if s.debugLoggingEnabled {
                        self.logger.log(
                            String(format: "ML filtered: %.2fg (ml=%.2f, sta=%.2f, final=%.2f, thresh=%.2f)",
                                   event.peakMagnitude, mlScore, event.staLtaScore, finalScore, threshold),
                            kind: .system
                        )
                    }
                    return
                }
            } else {
                self.lastTapScore = nil
            }

            // ── Mic confirmation gate ─────────────────────────────────────
            // When micConfirmationEnabled is on, cross-check the IMU event
            // against recent acoustic transients captured by MicInputService.
            // A genuine tap produces both a mechanical shock (IMU) and an acoustic
            // transient (mic) within a tight window (~10–20 ms). Events without
            // an acoustic counterpart are downgraded by `micUnconfirmedPenalty`.
            let s = self.store.settings
            if s.micEnabled && s.micConfirmationEnabled {
                let hasAcoustic = self.mic.transient(
                    near: event.timestamp,
                    windowSec: s.micCorrelationWindowSec
                ) != nil

                if !hasAcoustic {
                    let penalty = s.micUnconfirmedPenalty

                    if s.mlEnabled, let score = self.lastTapScore {
                        // ML is active: apply the penalty to the current score and
                        // re-check against the threshold.
                        let penalised = score * penalty
                        if self.store.settings.debugLoggingEnabled {
                            self.logger.log(
                                String(format: "Mic unconfirmed — score %.2f → %.2f (penalty %.1f×)",
                                       score, penalised, penalty),
                                kind: .system
                            )
                        }
                        if penalised < self.store.settings.mlScoreThreshold {
                            // Penalised score falls below ML floor — reject.
                            return
                        }
                        self.lastTapScore = penalised
                    } else {
                        // ML is not active: use penalty as a hard gate probability.
                        // penalty = 0.5 → 50 % of unconfirmed events are rejected.
                        if Double.random(in: 0...1) > penalty {
                            if self.store.settings.debugLoggingEnabled {
                                self.logger.log("Mic unconfirmed tap rejected (no-ML gate)", kind: .system)
                            }
                            return
                        }
                    }
                }
            }

            // Tap accepted — forward to gesture classifier with side detection.
            // Priority: mic TDOA (most accurate) → IMU centroid (no mic needed) → center.
            let side: TapSide
            let settings = self.store.settings
            if settings.micEnabled {
                side = self.mic.recentSide(since: event.timestamp.addingTimeInterval(-0.2))
            } else if settings.imuSideEnabled,
                      let features = event.features,
                      let sideModel = self.calibration.sideCalibrationData {
                side = sideModel.predictSide(features: features)
            } else {
                side = .center
            }
            self.classifier.registerTap(side: side)

            // Update the personal model only when confident the event is a real tap:
            //  1. Not within 2 s of a gyro-detected movement (laptop still settling).
            //  2. If the ML gate was active, the score must be ≥ 0.5 — well above the
            //     detection floor — so borderline events don't drift the model.
            let sinceMovement = Date().timeIntervalSince(self.lastMovementTime)
            let safeToLearn   = sinceMovement > 2.0
            if safeToLearn {
                if let score = self.lastTapScore {
                    if score >= 0.5 { self.calibration.recordAcceptedTap(event) }
                } else {
                    self.calibration.recordAcceptedTap(event)
                }
            } else if self.store.settings.debugLoggingEnabled {
                self.logger.log(
                    String(format: "Online learning frozen (%.1f s since movement)", sinceMovement),
                    kind: .system
                )
            }
        }

        input.onMovementRejected = { [weak self] gyroMag, threshold in
            guard let self else { return }
            self.lastMovementTime = Date()
            if self.store.settings.debugLoggingEnabled {
                self.logger.log(
                    String(format: "Movement filter: rejected (gyro %.2f rad/s > threshold %.2f rad/s)", gyroMag, threshold),
                    kind: .system
                )
            }
        }

        input.onTapFiltered = { [weak self] reason in
            guard let self, self.store.settings.debugLoggingEnabled else { return }
            self.logger.log("Tap filtered: \(reason)", kind: .system)
        }

        input.onDiagnosticSample = { [weak self] magnitude, threshold in
            guard let self, self.store.settings.debugLoggingEnabled else { return }
            self.logger.log(
                String(format: "IMU alive — mag %.4f g, threshold %.3f g", magnitude, threshold),
                kind: .system
            )
        }

        input.onAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            self.isAccelerometerAvailable = available
            if available {
                self.logger.log(
                    String(format: "Accelerometer connected (threshold %.3f g)", self.store.settings.tapThresholdG),
                    kind: .system
                )
            }
        }

        mic.onAvailabilityChanged = { [weak self] available in
            self?.isMicAvailable = available
        }

        // Update lastAcousticPeak so DetectionView can pulse the activity indicator.
        mic.onAcousticTap = { [weak self] _, peak in
            self?.lastAcousticPeak = peak
        }

        classifier.onGestureDetected = { [weak self] gesture in
            guard let self else { return }
            self.lastGesture = gesture
            self.gestureDetectionCount += 1
            self.logger.log("Detected: \(gesture.displayName)", kind: .detection)

            guard let binding = self.store.binding(for: gesture) else {
                if self.store.settings.debugLoggingEnabled {
                    self.logger.log("No binding defined for \(gesture.displayName)", kind: .system)
                }
                return
            }

            guard binding.enabled else {
                if self.store.settings.debugLoggingEnabled {
                    self.logger.log("Skipped: \(gesture.displayName) binding is disabled", kind: .system)
                }
                return
            }

            Task { [weak self] in
                guard let self else { return }
                await self.executor.execute(binding, logger: self.logger)
            }
        }
    }
}
