import Foundation

/// One differentiated 6-channel IMU sample (Δ per sample).
struct IMUSample: Sendable {
    let dax, day, daz: Double   // Δaccel (g / sample)
    let dgx, dgy, dgz: Double   // Δgyro  (rad/s / sample)
}

/// Fixed-capacity FIFO ring buffer for IMU samples.
/// All access must occur on the @MainActor.
final class IMUCircularBuffer {
    private var buf: [IMUSample]
    /// Monotonically increasing count of all appended samples.
    private(set) var writeCount: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        let z = IMUSample(dax: 0, day: 0, daz: 0, dgx: 0, dgy: 0, dgz: 0)
        buf = Array(repeating: z, count: capacity)
    }

    func append(_ s: IMUSample) {
        buf[writeCount % capacity] = s
        writeCount += 1
    }

    /// Extracts samples in the absolute index range [startIdx, startIdx+count).
    /// Returns fewer items if the range falls outside available history.
    func slice(from startIdx: Int, count n: Int) -> [IMUSample] {
        let first = max(startIdx, writeCount - capacity)
        let last  = min(startIdx + n, writeCount)
        guard first < last else { return [] }
        var out = [IMUSample]()
        out.reserveCapacity(last - first)
        for i in first..<last { out.append(buf[i % capacity]) }
        return out
    }
}
