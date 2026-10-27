import CoreGraphics
import Foundation

/// Wheel radii shared by the main-thread UI and the event-tap thread. Plain constants, no actor.
enum POWheelGeometry {
    /// Center cancel zone; also the inner radius of the sector ring.
    static let cancelRadius: CGFloat = 26
    static let outerRadius: CGFloat = 80
}

/// Recognizes Option + double-click, which clears every marker (design-system.md §8).
///
/// Runs on the event-tap thread: a pure value type with no AppKit, no locks, no waiting and no
/// allocation. Use one coordinate space for every call (CGEvent.location is fine).
///
/// Coordination with the wheel:
/// - The wheel still appears immediately on the first press; nothing is delayed.
/// - Both clicks happen inside one wheel session (Option held throughout) and land where a
///   release never executes anything: the center cancel zone. Beyond the ring is not neutral,
///   because the screen is divided by angle and a release there runs that sector (R126).
///   A double-click in place is always in the center, because the wheel is centered on the first press.
/// - It fires on the second release, and only if that click did not move. So a user who cancels
///   in the center and quickly presses again to drag to a function never clears by accident.
/// - Timing follows the system double-click interval: second press within it of the first
///   release, second release within it of the second press.
struct POClearGesture: Sendable {
    /// Pass `NSEvent.doubleClickInterval`, read on the main thread before the monitor starts.
    var interval: TimeInterval
    /// Max movement for a click, in points.
    var slop: CGFloat = 6

    private var center: CGPoint?
    private var press: (point: CGPoint, time: TimeInterval)?
    private var moved = false
    private var firstTap: (point: CGPoint, time: TimeInterval)?
    private var secondPress = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// An Option + left press that the gesture state machine swallowed.
    /// - Parameter startsSession: true when that press produced `.began`.
    mutating func down(at point: CGPoint, time: TimeInterval, startsSession: Bool) {
        moved = false
        press = (point, time)
        if startsSession {
            center = point
            firstTap = nil
            secondPress = false
            return
        }
        if let tap = firstTap, isNeutral(point),
           time - tap.time <= interval, Self.distance(point, tap.point) <= slop {
            secondPress = true
        } else {
            firstTap = nil
            secondPress = false
        }
    }

    mutating func dragged(to point: CGPoint) {
        if let press, Self.distance(point, press.point) > slop { moved = true }
    }

    /// The matching release. Returns true when it completes the clear gesture; the host then
    /// delivers its clear event. The release itself is handled by the state machine as usual
    /// (it lands on no function, so it executes nothing).
    mutating func up(at point: CGPoint, time: TimeInterval) -> Bool {
        defer { press = nil; moved = false }
        guard let press, !moved, isNeutral(press.point), isNeutral(point),
              time - press.time <= interval else {
            firstTap = nil
            secondPress = false
            return false
        }
        if secondPress {
            firstTap = nil
            secondPress = false
            return true
        }
        firstTap = (press.point, time)
        return false
    }

    /// The session ended or the press was not ours: Option released, Escape, tap interruption,
    /// a plain click, permission loss.
    mutating func reset() {
        center = nil
        press = nil
        moved = false
        firstTap = nil
        secondPress = false
    }

    /// Where a release never executes: only the center cancel zone (R126 gives every other point a sector).
    private func isNeutral(_ p: CGPoint) -> Bool {
        guard let center else { return false }
        return Self.distance(p, center) < POWheelGeometry.cancelRadius
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
