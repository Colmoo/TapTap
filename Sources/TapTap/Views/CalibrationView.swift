import SwiftUI

struct CalibrationView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        Form {
            statusSection
            sessionSection
            if env.calibration.isCalibrated {
                mlSection
            }
            sideCalibrationSection
        }
        .formStyle(.grouped)
        .navigationTitle("Calibration")
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section("Personal Model") {
            if let data = env.calibration.calibrationData {
                LabeledContent("State") {
                    modelStateLabel(data)
                }
                LabeledContent("Quality") {
                    gradeLabel(data.qualityGrade)
                }
                LabeledContent("Mean shape") {
                    Text(String(format: "%.2f×", data.meanCrestFactor))
                        .font(.system(.body, design: .monospaced))
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: data.meanCrestFactor)
                }
                LabeledContent("Spread") {
                    Text(String(format: "±%.2f×", data.stdCrestFactor))
                        .font(.system(.body, design: .monospaced))
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: data.stdCrestFactor)
                }
                if let d = data.learnedDoubleTapWindowMs {
                    LabeledContent("Double-tap window") {
                        Text(String(format: "%.0f ms", d))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if let t = data.learnedTripleTapWindowMs {
                    LabeledContent("Triple-tap window") {
                        Text(String(format: "%.0f ms", t))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                LabeledContent("Total taps learned") {
                    HStack(spacing: 6) {
                        Text("\(data.sampleCount)")
                            .font(.system(.body, design: .monospaced))
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: data.sampleCount)
                        if env.calibration.learnedTapCount > 0 {
                            Text("(+\(env.calibration.learnedTapCount) this session)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !env.calibration.isMLReady {
                    Text("Keep tapping — ML filter activates after \(CalibrationManager.minSamplesForMLGate) accepted taps.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text("Not calibrated")
                    }
                }
                Text("Run a guided session — it calibrates tap strength and automatically measures your natural double- and triple-tap timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelStateLabel(_ data: CalibrationData) -> some View {
        let isLearning = env.calibration.learnedTapCount > 0
        HStack(spacing: 6) {
            Circle()
                .fill(env.calibration.isMLReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(isLearning ? "Learning" : "Calibrated")
        }
    }

    // MARK: - Guided session

    @ViewBuilder
    private var sessionSection: some View {
        Section("Guided Session") {
            switch env.calibration.phase {
            case .idle:
                Text("A 3-step session: tap once 10 times, then double-tap 5 times, then triple-tap 3 times. Tap strength and timing windows are all set automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(env.calibration.isCalibrated ? "Recalibrate" : "Start Calibration") {
                        env.calibration.startCalibration()
                        if !env.isListening { env.startListening() }
                    }
                    .buttonStyle(.borderedProminent)
                    if env.calibration.isCalibrated {
                        Button("Reset Model", role: .destructive) {
                            env.calibration.reset()
                        }
                    }
                }

            case .collectingSingle:
                phaseHeader(step: 1, title: "Single taps", subtitle: "Tap the lid once at a time, naturally.")
                progressRow(
                    label: "Taps",
                    value: env.calibration.progress / 0.34,
                    current: env.calibration.collectedCount,
                    target: CalibrationManager.targetSampleCount
                )
                liveReadoutRow
                Text("Use your normal tapping force and position.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { env.calibration.cancel() }

            case .collectingDouble:
                phaseHeader(step: 2, title: "Double-taps", subtitle: "Tap twice in quick succession, 5 times total.")
                progressRow(
                    label: "Pairs",
                    value: Double(env.calibration.doubleSamplesCollected) / Double(CalibrationManager.targetDoubleSampleCount),
                    current: env.calibration.doubleSamplesCollected,
                    target: CalibrationManager.targetDoubleSampleCount
                )
                liveReadoutRow
                Text("Tap at the speed you'd naturally do a double-tap.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { env.calibration.cancel() }

            case .collectingTriple:
                phaseHeader(step: 3, title: "Triple-taps", subtitle: "Tap three times in quick succession, 3 times total.")
                progressRow(
                    label: "Triples",
                    value: Double(env.calibration.tripleSamplesCollected) / Double(CalibrationManager.targetTripleSampleCount),
                    current: env.calibration.tripleSamplesCollected,
                    target: CalibrationManager.targetTripleSampleCount
                )
                liveReadoutRow
                Text("Tap at the speed you'd naturally do a triple-tap.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { env.calibration.cancel() }

            case .complete:
                Text("Done! Tap strength and timing windows have been set automatically. The model keeps refining itself with every accepted tap.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Recalibrate") {
                    env.calibration.startCalibration()
                    if !env.isListening { env.startListening() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func phaseHeader(step: Int, title: String, subtitle: String, totalSteps: Int = 3) -> some View {
        HStack(spacing: 10) {
            Text("Step \(step) of \(totalSteps)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func progressRow(label: String, value: Double, current: Int, target: Int) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                ProgressView(value: min(1, value))
                    .frame(width: 140)
                    .animation(.easeInOut, value: value)
                Text("\(current) / \(target)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveReadoutRow: some View {
        LabeledContent("Last tap") {
            if env.calibration.lastRecordedMagnitude > 0 {
                HStack(spacing: 8) {
                    MagnitudeBar(magnitude: env.calibration.lastRecordedMagnitude)
                        .frame(width: 100, height: 8)
                        .animation(.easeOut(duration: 0.15), value: env.calibration.lastRecordedMagnitude)
                    Text(String(format: "%.2f g", env.calibration.lastRecordedMagnitude))
                        .font(.system(.caption, design: .monospaced))
                        .contentTransition(.numericText())
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - ML section

    private var mlSection: some View {
        Section("ML Filtering") {
            Toggle("Enable ML filtering", isOn: Binding(
                get: { env.store.settings.mlEnabled },
                set: { v in mutateSettings { $0.mlEnabled = v } }
            ))

            if env.store.settings.mlEnabled {
                SliderRow(
                    label: "Score threshold",
                    value: Binding(
                        get: { env.store.settings.mlScoreThreshold },
                        set: { v in mutateSettings { $0.mlScoreThreshold = v } }
                    ),
                    range: 0.05...0.6,
                    format: "%.2f"
                )

                if let score = env.lastTapScore {
                    LabeledContent("Last score") {
                        HStack(spacing: 8) {
                            ScoreBar(score: score, threshold: env.store.settings.mlScoreThreshold)
                                .frame(width: 100, height: 8)
                                .animation(.easeOut(duration: 0.15), value: score)
                            Text(String(format: "%.2f", score))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(score >= env.store.settings.mlScoreThreshold ? Color.primary : Color.red)
                                .contentTransition(.numericText())
                        }
                    }
                }

                Text("Higher = stricter (fewer false positives, may miss very light taps). The model learns your tap profile over time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Side calibration

    @ViewBuilder
    private var sideCalibrationSection: some View {
        Section("Side Detection (IMU)") {
            if env.calibration.isSideCalibrating {
                let phase = env.calibration.sidePhase ?? .left
                let step: Int   = phase == .left ? 1 : phase == .right ? 2 : 3
                let title       = phase == .left ? "Tap LEFT zone"   : phase == .right ? "Tap RIGHT zone"   : "Tap CENTER zone"
                let subtitle    = phase == .left
                    ? "Spread \(CalibrationManager.targetSideCount) taps across the full left keyboard area."
                    : phase == .right
                        ? "Spread \(CalibrationManager.targetSideCount) taps across the full right keyboard area."
                        : "Spread \(CalibrationManager.targetSideCount) taps across the trackpad and palm rest."
                let label       = phase == .left ? "Left taps" : phase == .right ? "Right taps" : "Center taps"

                phaseHeader(step: step, title: title, subtitle: subtitle, totalSteps: 3)
                progressRow(
                    label: label,
                    value: Double(env.calibration.sideCalibrationCount) / Double(CalibrationManager.targetSideCount),
                    current: env.calibration.sideCalibrationCount,
                    target: CalibrationManager.targetSideCount
                )
                Text("Tap naturally across the whole zone — not just the edges.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) {
                    env.calibration.cancelSideCalibration()
                }
            } else if let data = env.calibration.sideCalibrationData {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Calibrated (\(data.sampleCount) taps)")
                    }
                }
                LabeledContent("Calibrated") {
                    Text(data.calibratedAt, style: .date)
                        .foregroundStyle(.secondary)
                }
                Text("Enable \"IMU side detection\" in the Detection tab to use this model.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Recalibrate Sides") {
                        env.calibration.startSideCalibration()
                        if !env.isListening { env.startListening() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reset", role: .destructive) {
                        env.calibration.resetSideCalibration()
                    }
                }
            } else {
                Text("Train a 3-zone classifier (left keyboard / right keyboard / trackpad) using IMU cross-axis correlations. Tap each zone \(CalibrationManager.targetSideCount) times spread across the whole area.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Start Side Calibration") {
                    env.calibration.startSideCalibration()
                    if !env.isListening { env.startListening() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func mutateSettings(_ transform: (inout AppSettings) -> Void) {
        var s = env.store.settings
        transform(&s)
        env.store.update(settings: s)
        env.applySettings()
    }

    @ViewBuilder
    private func gradeLabel(_ grade: String) -> some View {
        let color: Color = switch grade {
        case "A": .green
        case "B": .blue
        case "C": .orange
        default:  .red
        }
        Text(grade)
            .font(.system(.body, design: .monospaced).bold())
            .foregroundStyle(color)
    }
}

// MARK: - Small reusable bars

private struct MagnitudeBar: View {
    let magnitude: Double
    private let maxG: Double = 5.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue)
                    .frame(width: geo.size.width * min(1, magnitude / maxG))
            }
        }
    }
}

private struct ScoreBar: View {
    let score: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(score >= threshold ? Color.green : Color.red)
                    .frame(width: geo.size.width * min(1, score))
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * threshold)
            }
        }
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
                    .frame(width: 160)
                Text(String(format: format, value))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}
