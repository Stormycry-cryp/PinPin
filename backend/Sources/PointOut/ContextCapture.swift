import AppKit
#if !PINPIN_APP_STORE
import ApplicationServices
#endif
import Foundation
import ScreenCaptureKit

final class CaptureCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var finished = false
    private var finishedHandlers: [() -> Void] = []
    func whenFinished(_ handler: @escaping () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if finished { return true }
            finishedHandlers.append(handler)
            return false
        }
        if runNow { handler() }
    }
    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let value = lock.withLock { () -> Value? in
            if finished { return pending }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }
    @discardableResult func finish(_ value: Value) -> Bool {
        var accepted = false
        var handlers: [() -> Void] = []
        let next = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard !finished else { return nil }
            accepted = true; finished = true
            handlers = finishedHandlers
            finishedHandlers.removeAll()
            pending = value
            defer { continuation = nil }
            return continuation
        }
        next?.resume(returning: value)
        handlers.forEach { $0() }
        return accepted
    }
    var isFinished: Bool { lock.withLock { finished } }
}

func boundedCapture<Value>(timeout: TimeInterval, fallback: @autoclosure @escaping () -> Value, cancelled: Value,
                                   start: @escaping (CaptureCompletion<Value>) -> Void) async -> Value {
    let completion = CaptureCompletion<Value>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            completion.install(continuation)
            guard !completion.isFinished else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                completion.finish(fallback())
            }
            start(completion)
        }
    } onCancel: {
        completion.finish(cancelled)
    }
}

#if !PINPIN_APP_STORE
private final class AXReadBudget {
    let deadline: TimeInterval
    private var remaining = 22
    private(set) var timedOut = false
    init(seconds: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
    func allow(_ element: AXUIElement) -> Bool {
        let time = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, time > 0 else { timedOut = true; return false }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, Float(min(0.035, time)))
        return true
    }
    func hit(_ application: AXUIElement, point: CGPoint) -> (AXUIElement?, AXError) {
        var lastError = AXError.cannotComplete
        let outcome: AXHitOutcome<AXUIElement> = AXHitRecovery.resolve(allowAttempt: { self.allow(application) }) {
            var hit: AXUIElement?
            lastError = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
            if lastError == .success, let hit { return .found(hit) }
            if lastError == .cannotComplete { self.timedOut = true; return .transientFailure }
            return .unavailable
        }
        if case .found(let element) = outcome { return (element, .success) }
        return (nil, lastError)
    }
    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard allow(element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .cannotComplete { timedOut = true }
        return error == .success ? value : nil
    }
    func parameter(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        guard allow(element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        if error == .cannotComplete { timedOut = true }
        return error == .success ? value : nil
    }
}

#endif

/// One frozen source-window frame, with an optional selection-only AX probe in direct builds.
/// All work is off the event-tap thread.
final class ContextCapture: @unchecked Sendable {
#if !PINPIN_APP_STORE
    private let axQueue = DispatchQueue(label: "PinPin.selection", qos: .userInitiated)
#endif
    private let visualQueue = DispatchQueue(label: "PinPin.snapshot", qos: .userInitiated)
    private let lock = NSLock()
    final class Frame: @unchecked Sendable {
        let image: CGImage
        let bounds: CGRect
        let point: CGPoint
        init(image: CGImage, bounds: CGRect, point: CGPoint) { self.image = image; self.bounds = bounds; self.point = point }
    }
    struct Snapshot: @unchecked Sendable {
        var frame: Frame?
        var source: String
    }
    private var frames: [UUID: Task<Snapshot, Never>] = [:]
    private let localSize = CGSize(width: 960, height: 640)
#if !PINPIN_APP_STORE
    private let selectionProbe: (@Sendable (TargetAnchor) async -> CapturedContext)?
#endif
    private let snapshotProvider: (@Sendable (TargetAnchor) async -> Snapshot)?
    private let colorSampler: @Sendable (CGPoint) async throws -> PickedColor
    private let screenCaptureAllowed: @Sendable () -> Bool

    init(selectionProbe: (@Sendable (TargetAnchor) async -> CapturedContext)? = nil,
         snapshotProvider: (@Sendable (TargetAnchor) async -> Snapshot)? = nil,
         screenCaptureAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
         colorSampler: @escaping @Sendable (CGPoint) async throws -> PickedColor = { try await PixelColorSampler().sample(at: $0) }) {
#if !PINPIN_APP_STORE
        self.selectionProbe = selectionProbe
#endif
        self.snapshotProvider = snapshotProvider
        self.screenCaptureAllowed = screenCaptureAllowed
        self.colorSampler = colorSampler
    }

    /// Independent from the encoded/model snapshot cache; cancellation of a prefetch cannot cancel this sample.
    func sampleColor(_ anchor: TargetAnchor) async throws -> PickedColor {
        try Task.checkCancellation()
        guard screenCaptureAllowed() else { throw PixelSamplingError.permissionDenied }
        let color = try await colorSampler(anchor.screenPoint)
        try Task.checkCancellation()
        return color
    }

    func capture(_ anchor: TargetAnchor) async -> CapturedContext {
        guard !Task.isCancelled else { return empty(anchor, "cancelled") }
        let frameTask = Task {
            if let provider = self.snapshotProvider { return await provider(anchor) }
            return await self.freeze(anchor)
        }
        let admitted = lock.withLock { () -> Bool in
            guard !Task.isCancelled else { return false }
            frames[anchor.id]?.cancel()
            frames[anchor.id] = frameTask
            return true
        }
        guard admitted else { frameTask.cancel(); return empty(anchor, "cancelled") }
        return await withTaskCancellationHandler {
            var result: CapturedContext
#if PINPIN_APP_STORE
            // Ignore injected selection probes too: the store build never reads another app through AX.
            result = empty(anchor, "selection_unavailable")
#else
            if let probe = selectionProbe { result = await probe(anchor) }
            else { result = await selection(anchor) }
#endif
            guard !Task.isCancelled else { forget(anchor.id); return empty(anchor, "cancelled") }
            if result.source == "ax_secure_content" || result.source == "selection_too_large" {
                forget(anchor.id); return result
            }
            result.screenCapturePermissionMissing = !screenCaptureAllowed()
            result.canCaptureVisual = !result.screenCapturePermissionMissing
            // Text actions can proceed before snapshot preparation. Explanation may attach it later.
            if result.hasSelection { return result }
            let snapshot = await frameTask.value
            guard !Task.isCancelled, lock.withLock({ frames[anchor.id] != nil }) else { return empty(anchor, "cancelled") }
            if let frame = snapshot.frame { result = encoded(result, frame: frame, expanded: false) }
            else { result.source = snapshot.source; result.screenCapturePermissionMissing = snapshot.source == "screen_permission_denied" || result.screenCapturePermissionMissing; forget(anchor.id) }
            return result
        } onCancel: { self.forget(anchor.id) }
    }

    /// Consumes the retained frame once. Results keep only the chosen encoded image, never the bitmap.
    func supplement(_ context: CapturedContext, anchor: TargetAnchor, plan: AcquisitionPlan) async -> CapturedContext {
        guard context.sessionID == anchor.id else { return context }
        let task = lock.withLock { frames.removeValue(forKey: anchor.id) }
        guard plan != .useCurrent, context.source != "ax_secure_content", context.source != "selection_too_large" else { task?.cancel(); return context }
        guard !Task.isCancelled, let task else { return context }
        let snapshot = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, let frame = snapshot.frame else { return context }
        return encoded(context, frame: frame, expanded: plan == .expandVisual)
    }

    func forget(_ id: UUID) { lock.withLock { frames.removeValue(forKey: id) }?.cancel() }

    private func encoded(_ context: CapturedContext, frame: Frame, expanded: Bool) -> CapturedContext {
        var result = context
        let crop = expanded ? frame.bounds : CaptureRules.crop(around: frame.point, in: frame.bounds, size: localSize)
        guard let crop, let image = VisualEvidence.encode(frame.image, crop: crop, frame: frame.bounds, pointer: frame.point) else { return result }
        result.imageData = image.marked
        result.originalImageData = image.original
        result.pointInImage = image.point
        result.imageMIME = "image/jpeg"
        result.canCaptureVisual = true
        result.canExpandVisual = !expanded && crop != frame.bounds
        result.source = result.hasSelection ? "ax_selection+visual" : (expanded ? "visual_window" : "visual_local")
        return result
    }

#if !PINPIN_APP_STORE
    private func selection(_ anchor: TargetAnchor) async -> CapturedContext {
        await boundedCapture(timeout: 0.20, fallback: self.empty(anchor, "selection_unavailable"), cancelled: empty(anchor, "cancelled")) { completion in
            self.axQueue.async {
                guard !completion.isFinished, AXIsProcessTrusted(), anchor.processID > 0, anchor.processID != getpid() else {
                    completion.finish(self.empty(anchor, "selection_unavailable")); return
                }
                let app = AXUIElementCreateApplication(anchor.processID)
                let budget = AXReadBudget(seconds: 0.17)
                let (hit, _) = budget.hit(app, point: anchor.screenPoint)
                guard let hit, !completion.isFinished else { completion.finish(self.empty(anchor, "selection_unavailable")); return }
                var pid: pid_t = 0; AXUIElementGetPid(hit, &pid)
                guard pid == anchor.processID else { completion.finish(self.empty(anchor, "source_changed")); return }
                if (budget.value(hit, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole {
                    completion.finish(self.empty(anchor, "ax_secure_content")); return
                }
                guard let range = Self.range(budget.value(hit, kAXSelectedTextRangeAttribute)), range.length > 0,
                      let parameter = Self.axRange(range),
                      let bounds = Self.rect(budget.parameter(hit, kAXBoundsForRangeParameterizedAttribute, parameter)),
                      CaptureRules.validSelection(range: range, bounds: bounds, point: anchor.screenPoint, hitProcess: pid, anchorProcess: anchor.processID) else {
                    completion.finish(self.empty(anchor, "selection_unavailable")); return
                }
                guard range.length <= 4000 else { completion.finish(self.empty(anchor, "selection_too_large")); return }
                guard let text = budget.parameter(hit, kAXStringForRangeParameterizedAttribute, parameter) as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion.finish(self.empty(anchor, "selection_unavailable")); return
                }
                var result = self.empty(anchor, "ax_selection")
                result.targetText = text; result.passageText = text
                completion.finish(result)
            }
        }
    }

#endif

    private func freeze(_ anchor: TargetAnchor) async -> Snapshot {
        await boundedCapture(timeout: 2, fallback: Snapshot(source: "visual_timeout"), cancelled: Snapshot(source: "cancelled")) { completion in
            self.visualQueue.async {
                guard !completion.isFinished, CGPreflightScreenCaptureAccess() else { completion.finish(Snapshot(source: "screen_permission_denied")); return }
                guard let frozen = self.sourceWindow(anchor) else { completion.finish(Snapshot(source: "source_unavailable")); return }
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
                    self.visualQueue.async {
                        guard !completion.isFinished,
                              let window = content?.windows.first(where: { $0.windowID == frozen.id && $0.owningApplication?.processID == anchor.processID }),
                              self.sourceWindow(anchor) == frozen, window.frame.contains(anchor.screenPoint) else {
                            completion.finish(Snapshot(source: "source_changed")); return
                        }
                        let bounds = window.frame
                        let scale = min(2, 2048 / max(bounds.width, bounds.height))
                        let config = SCStreamConfiguration()
                        config.ignoreShadowsSingleWindow = true
                        config.width = max(1, Int(bounds.width * scale)); config.height = max(1, Int(bounds.height * scale))
                        config.showsCursor = false
                        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) { image, _ in
                            self.visualQueue.async {
                                guard !completion.isFinished, let image, self.sourceWindow(anchor) == frozen else {
                                    completion.finish(Snapshot(source: "source_changed")); return
                                }
                                completion.finish(Snapshot(frame: Frame(image: image, bounds: bounds, point: anchor.screenPoint), source: "visual_ready"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func empty(_ anchor: TargetAnchor, _ source: String) -> CapturedContext {
        CapturedContext(sessionID: anchor.id, targetText: "", surroundingText: "",
                        appName: NSRunningApplication(processIdentifier: anchor.processID)?.localizedName ?? "",
                        windowTitle: "", source: source)
    }

    private func sourceWindow(_ anchor: TargetAnchor) -> CaptureWindowIdentity? {
        guard let id = anchor.windowID, let window = WindowIdentityLookup.read(id),
              window.processID == anchor.processID, window.processID != getpid(),
              window.frame.contains(anchor.screenPoint) else { return nil }
        return window
    }

#if !PINPIN_APP_STORE
    private static func axRange(_ range: NSRange) -> AXValue? {
        var r = CFRange(location: range.location, length: range.length); return AXValueCreate(.cfRange, &r)
    }
    private static func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect) ? rect : nil
    }
#endif
}
