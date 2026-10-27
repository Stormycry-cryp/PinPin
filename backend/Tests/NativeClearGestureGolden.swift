import CoreGraphics
import Foundation

/// Compile directly with the original UI-owned UIGestureRules.swift. No tap, AppKit UI, or model.
@main struct NativeClearGestureGolden {
    static func main() {
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            checked += 1
        }
        let center = CGPoint(x: -200, y: 300)
        func firstClick(_ rule: inout POClearGesture) -> Bool {
            rule.down(at: center, time: 1, startsSession: true)
            return rule.up(at: center, time: 1.05)
        }
        var rule = POClearGesture(interval: 0.3)
        check(!firstClick(&rule), "A single neutral click must not clear")
        rule.down(at: center, time: 1.15, startsSession: false)
        check(rule.up(at: center, time: 1.2), "Second stationary neutral release clears")
        check(!rule.up(at: center, time: 1.21), "Unmatched up cannot clear again")

        rule = POClearGesture(interval: 0.3)
        _ = firstClick(&rule)
        rule.down(at: center, time: 1.15, startsSession: false)
        rule.dragged(to: CGPoint(x: center.x + 20, y: center.y))
        check(!rule.up(at: center, time: 1.2), "Dragged second click must not clear even after returning")

        rule = POClearGesture(interval: 0.3)
        _ = firstClick(&rule)
        rule.down(at: center, time: 1.4, startsSession: false)
        check(!rule.up(at: center, time: 1.45), "Late second press must not clear")

        rule = POClearGesture(interval: 0.3)
        _ = firstClick(&rule)
        rule.down(at: center, time: 1.15, startsSession: false)
        check(!rule.up(at: center, time: 1.5), "Held second press must not clear")

        for resetReason in ["Option release", "Escape", "ordinary mouse", "tap interruption", "stop"] {
            rule = POClearGesture(interval: 0.3)
            _ = firstClick(&rule)
            rule.reset()
            rule.down(at: center, time: 1.15, startsSession: false)
            check(!rule.up(at: center, time: 1.2), "Reset must invalidate pending click: \(resetReason)")
        }

        rule = POClearGesture(interval: 0.3)
        _ = firstClick(&rule)
        rule.down(at: center, time: 1.15, startsSession: true)
        check(!rule.up(at: center, time: 1.2), "New session must not inherit previous tap")

        rule = POClearGesture(interval: 0.3)
        _ = firstClick(&rule)
        let function = CGPoint(x: center.x + 50, y: center.y)
        rule.down(at: function, time: 1.15, startsSession: false)
        check(!rule.up(at: function, time: 1.2), "Function-sector release must not clear")
        for offset in [CGPoint(x: 1200, y: 0), CGPoint(x: -1200, y: 0),
                       CGPoint(x: 0, y: 900), CGPoint(x: 0, y: -900)] {
            rule = POClearGesture(interval: 0.3)
            _ = firstClick(&rule)
            let outside = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            rule.down(at: outside, time: 1.15, startsSession: false)
            check(!rule.up(at: outside, time: 1.2), "First release beyond the wheel must not clear")
            rule.down(at: outside, time: 1.25, startsSession: false)
            check(!rule.up(at: outside, time: 1.3), "Two function-sector releases beyond the wheel must not clear")
        }

        print("Opus POClearGesture: \(checked) golden checks passed")
    }
}
