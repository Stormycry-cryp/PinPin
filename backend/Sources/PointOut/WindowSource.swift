import AppKit

/// The platform answers actual mouse hit-testing, including transparent and floating windows.
/// Pixel geometry only verifies the frozen identity later; it never decides occlusion.
enum WindowHitResolver {
    static func resolve(point: CGPoint, ownPID: pid_t,
                        hit: (Int) -> Int,
                        metadata: (CGWindowID) -> CaptureWindowIdentity?) -> CaptureWindowIdentity? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var below = 0
        var visited = Set<Int>()
        while true {
            let number = hit(below)
            guard number > 0, number <= Int(UInt32.max), visited.insert(number).inserted,
                  let window = metadata(CGWindowID(number)), window.id == CGWindowID(number),
                  CaptureRules.finite(window.frame), window.frame.contains(point), window.processID > 0 else { return nil }
            if window.processID != ownPID { return window }
            below = number
        }
    }
}

enum WindowIdentityLookup {
    static func read(_ id: CGWindowID) -> CaptureWindowIdentity? {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        guard let item = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              let pid = item[kCGWindowOwnerPID as String] as? Int32,
              let dictionary = item[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary), CaptureRules.finite(frame) else { return nil }
        return CaptureWindowIdentity(id: id, processID: pid, frame: frame)
    }
}

@MainActor enum TargetSourceResolver {
    static func anchor(from candidate: TargetAnchor) -> TargetAnchor {
        let point = CaptureRules.presentationPoint(candidate.screenPoint, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let source = WindowHitResolver.resolve(point: candidate.screenPoint, ownPID: getpid(), hit: { below in
            NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
        }, metadata: WindowIdentityLookup.read)
        return TargetAnchor(id: candidate.id, screenPoint: candidate.screenPoint, presentationPoint: point,
                            processID: source?.processID ?? 0, startedAt: candidate.startedAt,
                            windowID: source?.id, windowFrame: source?.frame)
    }
}
