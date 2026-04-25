import SwiftUI

struct DetectionView: View {
    @Environment(AppEnvironment.self) var env
    @State private var showGestureFlash = false
    @State private var lastGestureLabel = ""
    /// 0–1 level shown by the acoustic activity bar; decays with animation.
    @State private var acousticPulse: Double = 0

    var body: some View {
        Form {
            Section("Detection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(env.isListening ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(env.isListening ? "Listening" : "Idle")
                            .foregroundStyle(env.isListening ? .primary : .secondary)
                    }
                }

                LabeledContent("Accelerometer") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(env.isAccelerometerAvailable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(env.isAccelerometerAvailable ? "Connected" : "Unavailable")
                            .foregroundStyle(env.isAccelerometerAvailable ? .primary : .secondary)
                    }
                }

                LabeledContent("Gyroscope") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(env.isGyroscopeAvailable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(env.isGyroscopeAvailable ? "Connected" : "Unavailable")
                            .foregroundStyle(env.isGyroscopeAvailable ? .primary : .secondary)
                    }
                }
                Text("Uses the built-in IMU. Available on Apple Silicon MacBooks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Microphone side detection", isOn: Binding(
                    get: { env.store.settings.micEnabled },
                    set: { v in mutateSettings { $0.micEnabled = v } }
                ))
                if env.store.settings.micEnabled {
                    LabeledContent("Microphone") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(env.isMicAvailable ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(env.isMicAvailable ? "Active" : "Unavailable")
                                .foregroundStyle(env.isMicAvailable ? .primary : .secondary)
                            if env.isMicAvailable {
                                AcousticActivityBar(level: acousticPulse)
                                    .frame(width: 60, height: 8)
                            }
                        }
                    }
                }
                Text("Uses the built-in stereo microphones to detect which side of the keyboard was tapped (left / centre / right), adding up to 9 bindable gestures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("ML filter") {
                    HStack(spacing: 6) {
                        let active = env.calibration.isCalibrated && env.store.settings.mlEnabled
                        Circle()
                            .fill(active ? Color.blue : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(active ? "Active" : env.calibration.isCalibrated ? "Disabled" : "Not calibrated")
                            .foregroundStyle(active ? .primary : .secondary)
                    }
                }
            }

                if env.store.settings.micEnabled {
                    Section("Microphone Sensitivity") {
                        SliderRow(
                            label: "Detection threshold",
                            value: Binding(
                                get: { env.store.settings.micThresholdMultiplier },
                                set: { v in mutateSettings { $0.micThresholdMultiplier = v } }
                            ),
                            range: 2.0...20.0,
                            format: "%.1f×"
                        )
                        Text("Peak amplitude must exceed noise floor × this multiplier. Lower = more sensitive but more false positives.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        SliderRow(
                            label: "Centre threshold",
                            value: Binding(
                                get: { env.store.settings.micSideThresholdMs },
                                set: { v in mutateSettings { $0.micSideThresholdMs = v } }
                            ),
                            range: 0.05...0.6,
                            format: "%.2f ms"
                        )
                        Text("Max TDOA to classify as a centre tap. Max possible on a MacBook ≈ 0.82 ms.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Mic Confirmation (IMU accuracy)") {
                        Toggle("Confirm taps with microphone", isOn: Binding(
                            get: { env.store.settings.micConfirmationEnabled },
                            set: { v in mutateSettings { $0.micConfirmationEnabled = v } }
                        ))
                        Text("Cross-checks each IMU tap event against a matching acoustic transient. Events with no mic counterpart are downgraded, letting you set a lower IMU threshold to catch lighter taps without more false positives.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if env.store.settings.micConfirmationEnabled {
                            SliderRow(
                                label: "Correlation window",
                                value: Binding(
                                    get: { env.store.settings.micCorrelationWindowSec * 1000 },
                                    set: { v in mutateSettings { $0.micCorrelationWindowSec = v / 1000 } }
                                ),
                                range: 5...80,
                                format: "%.0f ms"
                            )
                            Text("How far apart the IMU and mic events can be and still count as the same knock. Genuine taps arrive within ~10–20 ms at both sensors.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SliderRow(
                                label: "Unconfirmed penalty",
                                value: Binding(
                                    get: { env.store.settings.micUnconfirmedPenalty },
                                    set: { v in mutateSettings { $0.micUnconfirmedPenalty = v } }
                                ),
                                range: 0.0...1.0,
                                format: "%.2f×"
                            )
                            Text("Score multiplier for IMU taps with no acoustic match. 0 = always reject; 1 = no penalty. Default 0.5 halves the ML score, vetoing borderline noise events while passing strong knocks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            Section("Signal Processing") {
                Toggle("Rebound check", isOn: Binding(
                    get: { env.store.settings.peakValleyCheckEnabled },
                    set: { v in mutateSettings { $0.peakValleyCheckEnabled = v } }
                ))
                Text("Requires the z-axis signal to have a characteristic bounce-back within 30 ms of the peak. Filters noise and slow desk bumps. Disable if genuine taps are being dropped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SliderRow(
                    label: "Gyro energy gate",
                    value: Binding(
                        get: { env.store.settings.gyroEnergyGateThreshold },
                        set: { v in mutateSettings { $0.gyroEnergyGateThreshold = v } }
                    ),
                    range: 0.0...0.5,
                    format: "%.3f"
                )
                Text("Minimum rotation energy (Σω²) during the tap window. Typing rarely couples into rotation so this gate cuts most keyboard false positives. Set to 0 to disable. Start low (~0.01) and raise if typing still triggers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !env.store.settings.micEnabled {
                    Toggle("IMU side detection", isOn: Binding(
                        get: { env.store.settings.imuSideEnabled },
                        set: { v in mutateSettings { $0.imuSideEnabled = v } }
                    ))
                    Text("Uses cross-axis correlation and rotational impulse direction to classify taps as left / centre / right without the microphone. Requires side calibration in the Calibration tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let f = env.lastTapEvent?.features {
                    LabeledContent("Roll coupling") {
                        Text(String(format: "%.3f", f.corr_az_gx))
                            .font(.system(.caption, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                    LabeledContent("Rise / FWHM") {
                        Text(String(format: "%.1f ms / %.1f ms", f.riseTime, f.fwhm))
                            .font(.system(.caption, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                    LabeledContent("Spectral (lo/mid/hi)") {
                        Text(String(format: "%.2f / %.2f / %.2f", f.spec_low, f.spec_mid, f.spec_high))
                            .font(.system(.caption, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                }
            }

            Section("Sensitivity") {
                SliderRow(
                    label: "Tap threshold",
                    value: Binding(
                        get: { env.store.settings.tapThresholdG },
                        set: { v in mutateSettings { $0.tapThresholdG = v } }
                    ),
                    range: 1.02...1.5,
                    format: "%.2f g"
                )
                Text("Acceleration magnitude that counts as a tap. Lower = more sensitive (light taps). At rest the device reads ~1 g; a gentle knock peaks at 1.05–1.1 g, a firm knock at 1.2–1.4 g.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SliderRow(
                    label: "Movement rejection",
                    value: Binding(
                        get: { env.store.settings.movementGyroThresholdRadS },
                        set: { v in mutateSettings { $0.movementGyroThresholdRadS = v } }
                    ),
                    range: 0.1...3.0,
                    format: "%.1f rad/s"
                )
                Text("Gyroscope threshold for rejecting whole-laptop movement. Events where rotation exceeds this are ignored. Lower = stricter (fewer false positives when moving the laptop). Set to max to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SliderRow(
                    label: "Peak cooldown",
                    value: Binding(
                        get: { env.store.settings.tapPeakCooldownMs },
                        set: { v in mutateSettings { $0.tapPeakCooldownMs = v } }
                    ),
                    range: 20...200,
                    format: "%.0f ms"
                )
                Text("Minimum time between tap events. Prevents a single knock from firing multiple times due to vibration echo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing (ms)") {
                SliderRow(
                    label: "Double-tap window",
                    value: Binding(
                        get: { env.store.settings.doubleTapWindowMs },
                        set: { v in mutateSettings { $0.doubleTapWindowMs = v } }
                    ),
                    range: 100...800,
                    format: "%.0f ms"
                )

                SliderRow(
                    label: "Triple-tap window",
                    value: Binding(
                        get: { env.store.settings.tripleTapWindowMs },
                        set: { v in mutateSettings { $0.tripleTapWindowMs = v } }
                    ),
                    range: 200...1200,
                    format: "%.0f ms"
                )

                SliderRow(
                    label: "Cooldown",
                    value: Binding(
                        get: { env.store.settings.globalCooldownMs },
                        set: { v in mutateSettings { $0.globalCooldownMs = v } }
                    ),
                    range: 250...5000,
                    format: "%.0f ms"
                )
            }

            Section("Test Mode") {
                if showGestureFlash {
                    HStack {
                        Image(systemName: "hand.tap.fill")
                            .foregroundStyle(.blue)
                        Text("Detected: \(lastGestureLabel)")
                            .bold()
                            .foregroundStyle(.blue)
                    }
                    .transition(.opacity.combined(with: .scale))
                }

                HStack(spacing: 12) {
                    Button("Simulate Tap") {
                        env.simulateTap()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Tap repeatedly to test single / double / triple recognition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: env.gestureDetectionCount) { _, _ in
            guard let gesture = env.lastGesture else { return }
            lastGestureLabel = gesture.displayName
            withAnimation(.easeOut(duration: 0.2)) { showGestureFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showGestureFlash = false }
            }
        }
        .onChange(of: env.lastAcousticPeak) { _, peak in
            // Pulse the bar immediately to the new peak level, then let it
            // decay back to zero over 400 ms so the waveform feel is natural.
            acousticPulse = Double(min(peak * 4, 1))   // amplify for visual impact
            withAnimation(.easeOut(duration: 0.4)) {
                acousticPulse = 0
            }
        }
    }

    private func mutateSettings(_ transform: (inout AppSettings) -> Void) {
        var s = env.store.settings
        transform(&s)
        env.store.update(settings: s)
        env.applySettings()
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: range)
                    .frame(width: 180)
                Text(String(format: format, value))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}

/// A small horizontal bar that fills proportionally to `level` (0–1) and
/// glows green, giving live visual feedback of acoustic transient strength.
private struct AcousticActivityBar: View {
    /// Current fill level in [0, 1].  Drive this from `env.lastAcousticPeak`
    /// with an easeOut decay animation for a natural VU-meter feel.
    var level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                // Fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.7), Color.green],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(level))
                    .shadow(color: .green.opacity(level > 0.05 ? 0.6 : 0), radius: 3)
            }
        }
    }
}
