import CoreGraphics
import Foundation

enum MigiPointerGestureOutcome: Equatable {
    case tap
    case drag
    case ignored
}

/// Classifies one pointer press without depending on AppKit's event cadence.
///
/// The maximum distance from mouse-down is authoritative. Once a press becomes
/// a drag it stays a drag, even if the pointer later returns to its start.
struct MigiPointerGesture {
    let dragThreshold: CGFloat
    let maximumTapDuration: TimeInterval

    private(set) var startPoint: CGPoint?
    private(set) var didDrag = false
    private var startedAt: TimeInterval?
    private var maximumDistance: CGFloat = 0

    init(
        dragThreshold: CGFloat = 4,
        maximumTapDuration: TimeInterval = 0.6
    ) {
        self.dragThreshold =
            dragThreshold.isFinite ? max(dragThreshold, 0) : 4
        self.maximumTapDuration =
            maximumTapDuration.isFinite ? max(maximumTapDuration, 0) : 0.6
    }

    var isActive: Bool {
        startPoint != nil && startedAt != nil
    }

    mutating func begin(at screenPoint: CGPoint, time: TimeInterval) {
        reset()
        guard screenPoint.isFinite, time.isFinite else { return }
        startPoint = screenPoint
        startedAt = time
    }

    /// Returns true on the update that first crosses the drag threshold.
    @discardableResult
    mutating func update(to screenPoint: CGPoint) -> Bool {
        guard let startPoint, screenPoint.isFinite else { return false }
        let distance = hypot(
            screenPoint.x - startPoint.x,
            screenPoint.y - startPoint.y
        )
        maximumDistance = max(maximumDistance, distance)
        let crossedThreshold = !didDrag && maximumDistance >= dragThreshold
        didDrag = didDrag || crossedThreshold
        return crossedThreshold
    }

    mutating func end(
        at screenPoint: CGPoint,
        time: TimeInterval
    ) -> MigiPointerGestureOutcome {
        guard let startedAt, time.isFinite, screenPoint.isFinite else {
            reset()
            return .ignored
        }
        update(to: screenPoint)
        let elapsed = time - startedAt
        let outcome: MigiPointerGestureOutcome
        if didDrag {
            outcome = .drag
        } else if elapsed >= 0, elapsed <= maximumTapDuration {
            outcome = .tap
        } else {
            outcome = .ignored
        }
        reset()
        return outcome
    }

    mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        startPoint = nil
        startedAt = nil
        didDrag = false
        maximumDistance = 0
    }
}

private extension CGPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}
