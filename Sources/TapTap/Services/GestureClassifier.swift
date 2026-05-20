import Foundation

/// Accumulates raw tap events and fires a classified GestureType after a debounce window.
///
/// Timeline example (doubleTapWindow = 300ms, tripleTapWindow = 500ms):
///   t=0ms    tap 1 → start 300ms timer
///   t=200ms  tap 2 → cancel, start 500ms timer from now
///   t=400ms  tap 3 → cancel, start 500ms timer from now
///   t=900ms  timer fires → count=3 → .triple (or .tripleLeft/.tripleRight when side ≠ .center)
///
/// The side of the FIRST tap in a sequence locks the side for the whole gesture.
@MainActor
final class GestureClassifier {
    var onGestureDetected: ((GestureType) -> Void)?

    var doubleTapWindow: TimeInterval = 0.3
    var tripleTapWindow: TimeInterval = 0.5
    var cooldown: TimeInterval = 1.0

    private var tapCount = 0
    private var currentSide: TapSide = .center
    private var pendingItem: DispatchWorkItem?
    private var isCoolingDown = false

    /// Register a tap with an optional side. Side is locked on the first tap
    /// of each sequence; subsequent taps in the same window keep the initial side.
    func registerTap(side: TapSide = .center) {
        guard !isCoolingDown else { return }

        if tapCount == 0 { currentSide = side }   // lock side on first tap
        tapCount += 1
        pendingItem?.cancel()

        let count = tapCount
        let lockedSide = currentSide
        let window = count >= 2 ? tripleTapWindow : doubleTapWindow

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tapCount = 0
            self.currentSide = .center
            self.fire(GestureType.make(count: count, side: lockedSide))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: item)
        pendingItem = item
    }

    private func fire(_ gesture: GestureType) {
        isCoolingDown = true
        onGestureDetected?(gesture)
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldown) { [weak self] in
            self?.isCoolingDown = false
        }
    }
}
