import SwiftUI

struct DetectionView: View {
    @Environment(AppEnvironment.self) var env
    @State private var showGestureFlash = false
    @State private var lastGestureLabel = ""

    private var noiseModelStatus: String {
        let m = env.noiseModel
        guard env.store.settings.noiseModelEnabled else { return "Paused" }
        if m.sampleCount == 0 { return "Waiting for noise events…" }
        if m.isActive { return "Active (\(m.sampleCount) samples)" }
        return "Learning (\(m.sampleCount) / \(NoiseModel.activationThreshold))"
    }

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

            Section("ML Filter") {
                Toggle("ML filter", isOn: Binding(
                    get: { env.store.settings.mlEnabled },
                    set: { v in mutateSettings { $0.mlEnabled = v } }
                ))
                if env.store.settings.mlEnabled {
                    SliderRow(
                        label: "Sensitivity",
                        value: Binding(
                            get: { env.store.settings.sensitivityBias },
                            set: { v in mutateSettings { $0.sensitivityBias = v } }
                        ),
                        range: -1.0...1.0,
                        format: "%.2f"
                    )
                    Text("Low (−1) catches lighter taps with more false positives. High (+1) is stricter. Auto-set from your calibration profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("STA/LTA energy gate", isOn: Binding(
                        get: { env.store.settings.staLtaEnabled },
                        set: { v in mutateSettings { $0.staLtaEnabled = v } }
                    ))
                    Text("Detects taps by energy spike relative to background noise. Lets soft taps through even before calibration. Disable only if you see false positives from desk vibration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Noise Model") {
                Toggle("Learn from noise", isOn: Binding(
                    get: { env.store.settings.noiseModelEnabled },
                    set: { v in mutateSettings { $0.noiseModelEnabled = v } }
                ))
                Text("Passively builds a profile of typing, desk bumps, and trackpad clicks from rejected events. No extra calibration needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status") {
                    Text(noiseModelStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if env.noiseModel.sampleCount > 0 {
                    Button("Reset noise model", role: .destructive) {
                        env.resetNoiseModel()
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
                Text("Acceleration magnitude that counts as a tap. Lower = more sensitive. At rest ~1 g; a gentle knock peaks at 1.05–1.1 g.")
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
                Text("Gyroscope threshold for rejecting whole-laptop movement. Set to max to disable.")
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
                Text("Minimum time between tap events. Prevents vibration echo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced") {
                Section {
                    Toggle("Rebound check", isOn: Binding(
                        get: { env.store.settings.peakValleyCheckEnabled },
                        set: { v in mutateSettings { $0.peakValleyCheckEnabled = v } }
                    ))
                    Text("Requires a z-axis bounce-back within 30 ms of peak. Filters slow desk bumps.")
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
                    Text("Minimum rotation energy during the tap window. Set to 0 to disable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if env.store.settings.mlEnabled {
                        SliderRow(
                            label: "Raw ML threshold",
                            value: Binding(
                                get: { env.store.settings.mlScoreThreshold },
                                set: { v in mutateSettings { $0.mlScoreThreshold = v; $0.userOverrodeMLThreshold = true } }
                            ),
                            range: 0.0...1.0,
                            format: "%.2f"
                        )
                        Text("Overrides the auto-derived threshold. Re-calibrate to restore automatic tuning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("IMU side detection", isOn: Binding(
                        get: { env.store.settings.imuSideEnabled },
                        set: { v in mutateSettings { $0.imuSideEnabled = v } }
                    ))
                    Text("Classifies taps as left/centre/right using IMU features. Requires side calibration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
            }
            .padding(.vertical, 4)

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
        .navigationTitle("Detection")
        .onChange(of: env.gestureDetectionCount) { _, _ in
            guard let gesture = env.lastGesture else { return }
            lastGestureLabel = gesture.displayName
            withAnimation(.easeOut(duration: 0.2)) { showGestureFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showGestureFlash = false }
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

