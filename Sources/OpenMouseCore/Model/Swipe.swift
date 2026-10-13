import Foundation

/// Hold-and-move gesture recognition.
public enum Swipe {
    /// Distance on the dominant axis needed to commit to a direction.
    public static let threshold = 50
    /// Minimum perpendicular tolerance before a swipe counts as diagonal.
    public static let deadzone = 40
    /// A swipe can only fire after the button has been held this long.
    public static let holdBeforeSwipe: TimeInterval = 0.16

    /// The direction for an accumulated `(dx, dy)` (+y is down), or `nil`
    /// while below threshold or too diagonal.
    public static func detect(dx: Int, dy: Int) -> GestureDirection? {
        let ax = dx == .min ? .max : abs(dx)
        let ay = dy == .min ? .max : abs(dy)
        let dominant = max(ax, ay)
        guard dominant >= threshold else { return nil }
        let crossLimit = max(deadzone, dominant > Int.max / 35 ? Int.max / 100 : dominant * 35 / 100)
        if ax > ay {
            guard ay <= crossLimit else { return nil }
            return dx > 0 ? .right : .left
        } else {
            guard ax <= crossLimit else { return nil }
            return dy > 0 ? .down : .up
        }
    }
}

/// Accumulates motion while a gesture-capable control is held.
public struct SwipeAccumulator: Sendable {
    public private(set) var heldSince: Date?
    public private(set) var dx = 0
    public private(set) var dy = 0
    public private(set) var fired = false

    public init() {}

    public var isHolding: Bool { heldSince != nil }

    public mutating func begin(at now: Date = Date()) {
        heldSince = now
        dx = 0
        dy = 0
        fired = false
    }

    /// Adds motion; returns a direction the first time a swipe commits.
    public mutating func accumulate(dx: Int, dy: Int, now: Date = Date()) -> GestureDirection? {
        guard !fired, let heldSince else { return nil }
        self.dx = self.dx.addingReportingOverflow(dx).partialValue
        self.dy = self.dy.addingReportingOverflow(dy).partialValue
        guard now.timeIntervalSince(heldSince) >= Swipe.holdBeforeSwipe,
              let direction = Swipe.detect(dx: self.dx, dy: self.dy) else { return nil }
        fired = true
        return direction
    }

    /// Ends the hold. Returns `true` when it was a plain click (no swipe fired).
    public mutating func end() -> Bool {
        let wasClick = heldSince != nil && !fired
        heldSince = nil
        return wasClick
    }
}
