import Foundation

// MARK: - TapWindow

/// A differentiated 6-channel IMU window aligned to a tap peak.
/// Contains ~30 ms of pre-peak and ~90 ms of post-peak data.
struct TapWindow: Sendable {
    let dax, day, daz: [Double]   // Δaccel channels
    let dgx, dgy, dgz: [Double]   // Δgyro  channels
    /// Index of the z-axis derivative peak within this window.
    let peakIdx: Int
    let sampleRate: Double

    // MARK: – Step 5: Rise time and FWHM

    func riseTimeMs() -> Double {
        guard peakIdx > 0, peakIdx < daz.count else { return 0 }
        let threshold = 0.1 * abs(daz[peakIdx])
        for i in stride(from: peakIdx, through: 0, by: -1) {
            if abs(daz[i]) < threshold {
                return Double(peakIdx - i) / sampleRate * 1_000
            }
        }
        return Double(peakIdx) / sampleRate * 1_000
    }

    func fwhmMs() -> Double {
        guard peakIdx < daz.count else { return 0 }
        let halfPeak = 0.5 * abs(daz[peakIdx])
        var left = peakIdx, right = peakIdx
        while left  > 0              && abs(daz[left])  > halfPeak { left  -= 1 }
        while right < daz.count - 1 && abs(daz[right]) > halfPeak { right += 1 }
        return Double(right - left) / sampleRate * 1_000
    }

    // MARK: – Step 6: Cross-axis Pearson correlations

    func crossAxisCorrelations() -> (az_gx: Double, az_gy: Double, az_gz: Double) {
        (TapWindow.pearson(daz, dgx),
         TapWindow.pearson(daz, dgy),
         TapWindow.pearson(daz, dgz))
    }

    // MARK: – Step 7: Rotational impulse direction

    func rotationalImpulse() -> (x: Double, y: Double, z: Double) {
        let dt = 1.0 / sampleRate
        let rx = dgx.reduce(0, +) * dt
        let ry = dgy.reduce(0, +) * dt
        let rz = dgz.reduce(0, +) * dt
        let mag = (rx*rx + ry*ry + rz*rz).squareRoot()
        guard mag > 1e-9 else { return (0, 0, 0) }
        return (rx/mag, ry/mag, rz/mag)
    }

    // MARK: – Step 8: Per-channel energy distribution

    func channelEnergyDistribution() -> [Double] {
        let channels = [dax, day, daz, dgx, dgy, dgz]
        let energies = channels.map { $0.reduce(0.0) { $0 + $1 * $1 } }
        let total = energies.reduce(0.0, +)
        guard total > 0 else { return Array(repeating: 1.0 / 6.0, count: 6) }
        return energies.map { $0 / total }
    }

    // MARK: – Step 9: Spectral band energy (z-axis DFT)
    // At the IMU sample rate (~200 Hz) the meaningful range is 0–100 Hz.
    // Band edges are adapted from the spec to fit within the available spectrum.

    func spectralBandEnergy() -> (low: Double, mid: Double, high: Double) {
        TapWindow.spectralBands(signal: daz, sampleRate: sampleRate)
    }

    static func spectralBands(signal: [Double], sampleRate: Double)
        -> (low: Double, mid: Double, high: Double)
    {
        let n = signal.count
        guard n >= 4 else { return (1.0/3, 1.0/3, 1.0/3) }

        let halfN  = n / 2
        let binHz  = sampleRate / Double(n)
        let lowEnd  = max(1, min(halfN, Int(20.0  / binHz)))
        let midEnd  =        min(halfN, Int(80.0  / binHz))
        let highEnd =        min(halfN, Int(200.0 / binHz))

        var power = [Double](repeating: 0, count: halfN)
        for k in 0..<halfN {
            var re = 0.0, im = 0.0
            let phase = 2.0 * .pi * Double(k) / Double(n)
            for t in 0..<n {
                let a = phase * Double(t)
                re += signal[t] * cos(a)
                im -= signal[t] * sin(a)
            }
            power[k] = re*re + im*im
        }

        let low  = lowEnd  < midEnd  ? power[lowEnd..<midEnd].reduce(0, +)  : 0
        let mid  = midEnd  < highEnd ? power[midEnd..<highEnd].reduce(0, +) : 0
        let high = highEnd < halfN   ? power[highEnd..<halfN].reduce(0, +)  : 0
        let total = low + mid + high + 1e-12

        return (low/total, mid/total, high/total)
    }

    // MARK: – Step 10: Assemble feature vector

    func featureVector() -> TapFeatureVector {
        let corr   = crossAxisCorrelations()
        let rot    = rotationalImpulse()
        let energy = channelEnergyDistribution()
        let spec   = spectralBandEnergy()
        return TapFeatureVector(
            riseTime:   riseTimeMs(),
            fwhm:       fwhmMs(),
            corr_az_gx: corr.az_gx,
            corr_az_gy: corr.az_gy,
            corr_az_gz: corr.az_gz,
            rot_x:      rot.x,
            rot_y:      rot.y,
            rot_z:      rot.z,
            energy:     energy,
            spec_low:   spec.low,
            spec_mid:   spec.mid,
            spec_high:  spec.high
        )
    }

    // MARK: – Private helpers

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n > 1 else { return 0 }
        let nd = Double(n)
        let mx = x.prefix(n).reduce(0, +) / nd
        let my = y.prefix(n).reduce(0, +) / nd
        var num = 0.0, dx2 = 0.0, dy2 = 0.0
        for i in 0..<n {
            let ex = x[i] - mx, ey = y[i] - my
            num += ex * ey; dx2 += ex * ex; dy2 += ey * ey
        }
        guard dx2 > 0, dy2 > 0 else { return 0 }
        return num / (dx2 * dy2).squareRoot()
    }
}

// MARK: - TapFeatureVector

/// 17-scalar feature vector assembled from a TapWindow (Steps 5–9).
struct TapFeatureVector: Codable, Sendable {
    var riseTime: Double        // ms — time from 10% to peak of daz
    var fwhm: Double            // ms — full-width-at-half-maximum of daz peak
    var corr_az_gx: Double      // Pearson r(daz, dgx) — roll coupling → left/right
    var corr_az_gy: Double      // Pearson r(daz, dgy) — pitch coupling → front/back
    var corr_az_gz: Double      // Pearson r(daz, dgz) — yaw coupling
    var rot_x: Double           // normalised rotational impulse x
    var rot_y: Double
    var rot_z: Double
    var energy: [Double]        // 6-element channel energy [ax,ay,az,gx,gy,gz]
    var spec_low: Double        // spectral fraction below ~20 Hz
    var spec_mid: Double        // spectral fraction 20–80 Hz
    var spec_high: Double       // spectral fraction above 80 Hz

    func toArray() -> [Double] {
        [riseTime, fwhm, corr_az_gx, corr_az_gy, corr_az_gz,
         rot_x, rot_y, rot_z] + energy + [spec_low, spec_mid, spec_high]
    }
}

// MARK: - SideCalibrationData

/// Nearest-centroid classifier for left/right side detection via IMU features.
/// Calibrate by collecting ~20 labelled taps per side and calling `fit(left:right:)`.
struct SideCalibrationData: Codable, Sendable {
    let calibratedAt: Date
    let leftCentroid: [Double]   // mean feature vector for left taps
    let rightCentroid: [Double]  // mean feature vector for right taps
    let sampleCount: Int

    /// Classify a feature vector by nearest Euclidean centroid.
    func predictSide(features: TapFeatureVector) -> TapSide {
        let fv = features.toArray()
        guard fv.count == leftCentroid.count,
              fv.count == rightCentroid.count else { return .center }
        let dLeft  = euclidean(fv, leftCentroid)
        let dRight = euclidean(fv, rightCentroid)
        if dLeft < dRight { return .left }
        if dRight < dLeft { return .right }
        return .center
    }

    static func fit(leftSamples: [[Double]], rightSamples: [[Double]]) -> SideCalibrationData? {
        guard !leftSamples.isEmpty, !rightSamples.isEmpty,
              let dim = leftSamples.first?.count, dim > 0 else { return nil }
        func mean(_ samples: [[Double]]) -> [Double] {
            let n = Double(samples.count)
            return (0..<dim).map { i in samples.map { $0[i] }.reduce(0, +) / n }
        }
        return SideCalibrationData(
            calibratedAt:   Date(),
            leftCentroid:   mean(leftSamples),
            rightCentroid:  mean(rightSamples),
            sampleCount:    leftSamples.count + rightSamples.count
        )
    }
}

private func euclidean(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
}
