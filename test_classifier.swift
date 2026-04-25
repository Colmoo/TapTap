import Foundation

// Copying minimal pieces logic
enum TapSide { case center, left, right }
enum GestureType {
    case single, double, triple
    static func make(count: Int, side: TapSide) -> GestureType {
        return count >= 3 ? .triple : count == 2 ? .double : .single
    }
}

class GestureClassifier {
    var onGestureDetected: ((GestureType) -> Void)?
    var doubleTapWindow: TimeInterval = 0.3
    var tripleTapWindow: TimeInterval = 0.5
    var cooldown: TimeInterval = 1.0

    private var tapCount = 0
    private var currentSide: TapSide = .center
    private var pendingItem: DispatchWorkItem?
    private var isCoolingDown = false

    func registerTap(side: TapSide = .center) {
        guard !isCoolingDown else { return }
        if tapCount == 0 { currentSide = side }
        tapCount += 1
        pendingItem?.cancel()

        let count = tapCount
        let lockedSide = currentSide
        let window = count >= 2 ? tripleTapWindow : doubleTapWindow

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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

let c = GestureClassifier()
c.onGestureDetected = { g in print("Detected", g) }

print("Tapping once...")
c.registerTap()

RunLoop.main.run(until: Date().addingTimeInterval(2.0))
