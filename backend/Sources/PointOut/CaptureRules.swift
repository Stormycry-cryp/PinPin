import Foundation
import CoreGraphics

/// Own both edges of the settings shortcut, even when Option is released first.
struct SettingsShortcutStateMachine {
    enum Input { case down(eligible: Bool), dragged, up, interrupted(buttonIsDown: Bool) }
    struct Decision { var swallow = false; var openSettings = false }
    private(set) var ownsButton = false

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .down(let eligible):
            guard !ownsButton else { return Decision(swallow: true) }
            guard eligible else { return Decision() }
            ownsButton = true
            return Decision(swallow: true, openSettings: true)
        case .dragged:
            return Decision(swallow: ownsButton)
        case .up:
            let owned = ownsButton
            ownsButton = false
            return Decision(swallow: owned)
        case .interrupted(let held):
            ownsButton = ownsButton && held
            return Decision()
        }
    }
}

/// Event ownership is independent of the wheel lifetime. A cancelled gesture still owns its up.
struct GestureStateMachine {
    enum Input { case down(option: Bool), dragged, up, optionReleased, escape, interrupted(buttonIsDown: Bool) }
    enum Action: Equatable { case began, moved, released, closed }
    struct Decision { var swallow = false; var actions: [Action] = [] }
    private(set) var wheelOpen = false
    private(set) var ownsButton = false

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .down(let option):
            guard option else {
                // A fresh ordinary down proves any previous physical up was missed while disabled.
                let wasOpen = wheelOpen
                wheelOpen = false; ownsButton = false
                return Decision(actions: wasOpen ? [.closed] : [])
            }
            // A duplicate down must not create a second session or change the original anchor.
            guard !ownsButton else { return Decision(swallow: true) }
            ownsButton = true
            if wheelOpen { return Decision(swallow: true, actions: [.moved]) }
            wheelOpen = true
            return Decision(swallow: true, actions: [.began])
        case .dragged:
            return Decision(swallow: ownsButton, actions: ownsButton && wheelOpen ? [.moved] : [])
        case .up:
            guard ownsButton else { return Decision() }
            ownsButton = false
            return Decision(swallow: true, actions: wheelOpen ? [.released] : [])
        case .optionReleased, .escape:
            let wasOpen = wheelOpen
            wheelOpen = false
            return Decision(actions: wasOpen ? [.closed] : [])
        case .interrupted(let buttonIsDown):
            let wasOpen = wheelOpen
            wheelOpen = false
            // If the physical up passed while a tap was disabled, do not consume a later click.
            ownsButton = ownsButton && buttonIsDown
            return Decision(actions: wasOpen ? [.closed] : [])
        }
    }
}

enum AXHitOutcome<Value> {
    case found(Value)
    case transientFailure
    case unavailable
}

/// Recover one failed AX message, without retrying unsupported/invalid/permission failures.
enum AXHitRecovery {
    static func resolve<Value>(allowAttempt: () -> Bool,
                               query: () -> AXHitOutcome<Value>) -> AXHitOutcome<Value> {
        guard allowAttempt() else { return .unavailable }
        let first = query()
        guard case .transientFailure = first, allowAttempt() else { return first }
        return query()
    }
}

struct CaptureWindowIdentity: Equatable {
    let id: CGWindowID
    let processID: Int32
    let frame: CGRect
}

enum CaptureRules {
    static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    static func presentationPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func validSelection(range: NSRange, bounds: CGRect?, point: CGPoint,
                               hitProcess: Int32, anchorProcess: Int32) -> Bool {
        guard hitProcess > 0, hitProcess == anchorProcess, range.location != NSNotFound,
              range.location >= 0, range.length > 0, let bounds, finite(bounds), point.x.isFinite, point.y.isFinite else { return false }
        return bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Crop around the frozen click, bounded to its source window.
    static func crop(around point: CGPoint, in display: CGRect, size: CGSize = CGSize(width: 960, height: 640)) -> CGRect? {
        guard finite(display), point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, display.contains(point) else { return nil }
        let width = min(size.width, display.width), height = min(size.height, display.height)
        return CGRect(x: min(max(point.x - width / 2, display.minX), display.maxX - width),
                      y: min(max(point.y - height / 2, display.minY), display.maxY - height),
                      width: width, height: height)
    }

    static func normalizedPoint(_ point: CGPoint, in crop: CGRect) -> CGPoint? {
        guard finite(crop), point.x.isFinite, point.y.isFinite, crop.contains(point) else { return nil }
        return CGPoint(x: (point.x - crop.minX) / crop.width, y: (point.y - crop.minY) / crop.height)
    }
}
