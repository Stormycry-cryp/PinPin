import AppKit
import ApplicationServices
import Foundation

/// All tap state belongs to the dedicated run loop. No AX, capture, or main-thread calls occur in its callback.
final class GlobalGestureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (GestureEvent) -> Void)?
    private var settingsCallback: (@Sendable () -> Void)?
    private var triggerEnabled = true
    private var cancellationRevision: UInt64 = 0
    private var appliedCancellationRevision: UInt64 = 0
    private var runGeneration: UInt64 = 0
    var onSettingsRequested: (@Sendable () -> Void)? {
        get { lock.withLock { settingsCallback } }
        set { lock.withLock { settingsCallback = newValue } }
    }
    var onEvent: (@Sendable (GestureEvent) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    private var recognizer: (@Sendable (NativeGestureSample) -> Bool)?
    /// Runs synchronously on the tap thread. Install before start; only use plain value rules.
    var recognizeNativeGesture: (@Sendable (NativeGestureSample) -> Bool)? {
        get { lock.withLock { recognizer } }
        set { lock.withLock { recognizer = newValue } }
    }
    private var primaryHeight: CGFloat = 0
    private var loop: CFRunLoop?
    private var thread: Thread?
    private var tap: CFMachPort?
    private var state = GestureStateMachine()
    private var settingsState = SettingsShortcutStateMachine()
    private var stopping = false
    private var stopRequested = false
    private var swallowingEscape = false

    init(wheelTriggerEnabled: Bool = true) { triggerEnabled = wheelTriggerEnabled }

    func setWheelTriggerEnabled(_ enabled: Bool) {
        let (runLoop, generation) = lock.withLock {
            triggerEnabled = enabled
            if !enabled { cancellationRevision &+= 1 }
            return (loop, runGeneration)
        }
        guard !enabled, let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, self.lock.withLock({ self.runGeneration == generation }) else { return }
            self.applyPendingWheelCancellation()
        }
        CFRunLoopWakeUp(runLoop)
    }

    func start() -> Bool {
        guard lock.withLock({ thread == nil }) else { return lock.withLock { !stopRequested && tap != nil } }
        lock.withLock { stopRequested = false }
        refreshScreenGeometry()
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.run(ready: ready)
        }
        worker.name = "PointOut.global-gesture"
        worker.qualityOfService = .userInteractive
        lock.withLock { thread = worker }
        worker.start()
        // start only creates a tap; it never waits for a target app to respond.
        guard ready.wait(timeout: .now() + 1) == .success else { stop(); return false }
        let running = lock.withLock { tap != nil }
        return running
    }

    func stop() {
        guard let runLoop = lock.withLock({ () -> CFRunLoop? in
            stopRequested = true
            return loop
        }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.recognize(.reset)
            self.deliver(self.state.handle(.optionReleased), point: .zero, event: nil)
            // Keep swallowing until the paired physical up. Removing a tap early leaks an orphan up.
            if !self.state.ownsButton && !self.settingsState.ownsButton && !self.swallowingEscape { CFRunLoopStop(runLoop) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func run(ready: DispatchSemaphore) {
        recognize(.reset)
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown, .keyUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: mask,
                                            callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<GlobalGestureMonitor>.fromOpaque(info).takeUnretainedValue().receive(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            lock.withLock { thread = nil }
            ready.signal()
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        lock.withLock { tap = newTap; loop = runLoop; runGeneration &+= 1; appliedCancellationRevision = cancellationRevision }
        state = GestureStateMachine()
        settingsState = SettingsShortcutStateMachine()
        stopping = lock.withLock { stopRequested }
        swallowingEscape = false
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        ready.signal()
        if !stopping { CFRunLoopRun() }
        recognize(.reset)
        CGEvent.tapEnable(tap: newTap, enable: false)
        CFMachPortInvalidate(newTap)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        lock.withLock { tap = nil; loop = nil; thread = nil }
    }

    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recognize(.reset)
            let held = CGEventSource.buttonState(.combinedSessionState, button: .left)
            _ = settingsState.handle(.interrupted(buttonIsDown: CGEventSource.buttonState(.combinedSessionState, button: .right)))
            swallowingEscape = swallowingEscape && CGEventSource.keyState(.combinedSessionState, key: 53)
            deliver(state.handle(.interrupted(buttonIsDown: held)), point: event.location, event: event)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let tap, !CGEvent.tapIsEnabled(tap: tap) { onEvent?(.permissionLost) }
            stopIfReleased()
            return Unmanaged.passUnretained(event)
        }
        if type == .rightMouseDown || type == .otherMouseDown { recognize(.reset) }
        applyPendingWheelCancellation()
        let settingsInput: SettingsShortcutStateMachine.Input?
        switch type {
        case .rightMouseDown: settingsInput = .down(eligible: Self.settingsShortcutEligible(event.flags, stopping: stopping))
        case .rightMouseDragged: settingsInput = .dragged
        case .rightMouseUp: settingsInput = .up
        default: settingsInput = nil
        }
        if let settingsInput {
            let decision = settingsState.handle(settingsInput)
            if decision.openSettings {
                deliver(state.handle(.optionReleased), point: event.location, event: event)
                onSettingsRequested?()
            }
            stopIfReleased()
            return decision.swallow ? nil : Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            if type == .keyUp, swallowingEscape {
                swallowingEscape = false
                stopIfReleased()
                return nil
            }
            if type == .keyDown, swallowingEscape { return nil }
        }
        let input: GestureStateMachine.Input?
        switch type {
        case .leftMouseDown: input = .down(option: state.ownsButton || (!stopping && lock.withLock({ triggerEnabled }) && event.flags.contains(.maskAlternate)))
        case .leftMouseDragged: input = .dragged
        case .leftMouseUp: input = .up
        case .flagsChanged: input = event.flags.contains(.maskAlternate) ? nil : .optionReleased
        case .keyDown:
            input = event.getIntegerValueField(.keyboardEventKeycode) == 53 ? .escape : nil
        default: input = nil
        }
        guard let input else { return Unmanaged.passUnretained(event) }
        let wasOwned = state.ownsButton
        var decision = state.handle(input)
        if let sample = Self.nativeSample(input: input, decision: decision, wasOwned: wasOwned,
                                          point: event.location, time: Double(event.timestamp) / 1_000_000_000) {
            recognize(sample)
        }
        if type == .keyDown, !decision.actions.isEmpty { decision.swallow = true; swallowingEscape = true }
        deliver(decision, point: event.location, event: event)
        stopIfReleased()
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    static func settingsShortcutEligible(_ flags: CGEventFlags, stopping: Bool) -> Bool {
        !stopping && flags.contains(.maskAlternate) && flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
    }

    private func stopIfReleased() {
        if stopping && !state.ownsButton && !settingsState.ownsButton && !swallowingEscape, let loop { CFRunLoopStop(loop) }
    }

    private func applyPendingWheelCancellation() {
        let revision = lock.withLock { cancellationRevision }
        guard revision != appliedCancellationRevision else { return }
        appliedCancellationRevision = revision
        recognize(.reset)
        deliver(state.handle(.optionReleased), point: .zero, event: nil)
    }

    /// Ownership routing only. Double-click timing and geometry belong to the injected UI rule.
    static func nativeSample(input: GestureStateMachine.Input, decision: GestureStateMachine.Decision,
                             wasOwned: Bool, point: CGPoint, time: TimeInterval) -> NativeGestureSample? {
        switch input {
        case .down:
            guard decision.swallow else { return .reset }
            guard !wasOwned else { return nil } // Duplicate down cannot replace the original press.
            return .down(point: point, time: time, startsSession: decision.actions.contains(.began))
        case .dragged:
            return decision.swallow ? .dragged(point) : .reset
        case .up:
            return decision.swallow && wasOwned && decision.actions.contains(.released) ? .up(point: point, time: time) : .reset
        case .optionReleased, .escape, .interrupted:
            return .reset
        }
    }

    private func recognize(_ sample: NativeGestureSample) {
        let completed = recognizeNativeGesture?(sample) ?? false
        // Only a matching, swallowed release may publish a clear command.
        if completed, case .up = sample { onEvent?(.clearAllMarkers) }
    }

    private func deliver(_ decision: GestureStateMachine.Decision, point: CGPoint, event: CGEvent?) {
        guard !decision.actions.isEmpty else { return }
        let snapshot = lock.withLock { (primaryHeight, callback) }
        let appKitPoint = CaptureRules.presentationPoint(point, primaryHeight: snapshot.0)
        for action in decision.actions {
            switch action {
            case .began:
                // Resolve the actual source once on main, before the wheel appears.
                snapshot.1?(.began(TargetAnchor(id: UUID(), screenPoint: point, presentationPoint: appKitPoint,
                                               processID: 0, startedAt: ProcessInfo.processInfo.systemUptime)))
            case .moved: snapshot.1?(.moved(appKitPoint))
            case .released: snapshot.1?(.released(appKitPoint))
            case .closed: snapshot.1?(.closed)
            }
        }
    }

    func refreshScreenGeometry() {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        lock.withLock { primaryHeight = height }
    }
}
