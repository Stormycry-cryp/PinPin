import AppKit
#if !PINPIN_APP_STORE
import ApplicationServices
#endif

@MainActor protocol ResultSourceObserving: AnyObject {
    var onChange: ((UUID, CGPoint, Bool) -> Void)? { get set }
    var onClosed: ((UUID) -> Void)? { get set }
    func track(_ anchor: TargetAnchor)
    func forget(_ id: UUID)
    func stop()
}

struct ResultSourceWindow: Equatable {
    let id: CGWindowID
    let processID: pid_t
    let frame: CGRect
    let onScreen: Bool
}

struct ResultSourceSnapshot {
    var windows: [CGWindowID: ResultSourceWindow] = [:]
    var hiddenProcesses: Set<pid_t> = []
    var primaryHeight: CGFloat = 0
}

enum ResultSourceEvent {
    case refresh
    case destroyed(pid_t, Set<CGWindowID>)
    case terminated(pid_t)
}

/// No AX RPC is permitted in these main-actor entry points.
@MainActor protocol ResultSourceBackend: AnyObject {
    var snapshotsAreDeferred: Bool { get }
    func snapshot(processes: Set<pid_t>) -> ResultSourceSnapshot
    func start(_ receive: @escaping (ResultSourceEvent) -> Void)
    func watch(_ pid: pid_t, windows: [CGWindowID: CGRect])
    func unwatch(_ pid: pid_t)
    func stop()
}

extension ResultSourceBackend {
    var snapshotsAreDeferred: Bool { false }
}

/// Follows completed window events. AX move notifications do not describe every drag frame.
@MainActor final class WindowResultObserver: ResultSourceObserving {
    var onChange: ((UUID, CGPoint, Bool) -> Void)?
    var onClosed: ((UUID) -> Void)?

    private struct Entry {
        let anchor: TargetAnchor
        let originalFrame: CGRect?
        var lastPoint: CGPoint?
        var lastVisible: Bool?
    }
    private let backend: ResultSourceBackend
    private var entries: [UUID: Entry] = [:]
    private var watched: Set<pid_t> = []
    private var generation = UUID()
    private var pending = false
    private var started = false
    private var stopped = false
    private var latestSnapshot = ResultSourceSnapshot()

    init(backend: ResultSourceBackend? = nil) {
        self.backend = backend ?? SystemResultSourceBackend()
    }

    func track(_ anchor: TargetAnchor) {
        guard !stopped else { return }
        forget(anchor.id)
        if !started {
            started = true
            let token = generation
            backend.start { [weak self] event in
                guard let self, self.started, self.generation == token else { return }
                self.receive(event)
            }
        }
        let processes = Set(entries.values.map { $0.anchor.processID }).union([anchor.processID]).filter { $0 > 0 }
        let snapshot = backend.snapshot(processes: Set(processes))
        let source = anchor.windowID.flatMap { snapshot.windows[$0] }
        var original = source?.processID == anchor.processID && source.map({ CaptureRules.finite($0.frame) }) == true ? source?.frame : nil
#if PINPIN_APP_STORE
        if backend.snapshotsAreDeferred { original = nil }
        // The first asynchronous snapshot may arrive after the source has moved.
        // Preserve the geometry frozen by the trigger's window hit test.
        if anchor.windowID != nil, let frame = anchor.windowFrame, CaptureRules.finite(frame) {
            original = frame
        }
#endif
        entries[anchor.id] = Entry(anchor: anchor, originalFrame: original)
#if PINPIN_APP_STORE
        if backend.snapshotsAreDeferred {
            // A cached result predating this trigger cannot prove the new source's identity.
            // Wait for this watch's query before showing or closing the new result.
            entries[anchor.id]?.lastPoint = anchor.presentationPoint
            entries[anchor.id]?.lastVisible = false
            onChange?(anchor.id, anchor.presentationPoint, false)
            synchronizeWatches(snapshot)
            return
        }
#endif
        apply(snapshot)
    }

    func forget(_ id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        synchronizeWatches()
        if entries.isEmpty {
            generation = UUID()
            pending = false
            backend.stop()
            started = false
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        generation = UUID()
        pending = false
        entries.removeAll()
        watched.removeAll()
        backend.stop()
        started = false
    }

    private func receive(_ event: ResultSourceEvent) {
        guard !stopped, !entries.isEmpty else { return }
        switch event {
        case .refresh: break
        case .destroyed(let pid, let windows):
            close(entries.values.filter { $0.anchor.processID == pid && $0.anchor.windowID.map(windows.contains) == true }.map { $0.anchor.id })
        case .terminated(let pid):
            close(entries.values.filter { $0.anchor.processID == pid }.map { $0.anchor.id })
        }
        scheduleRefresh()
    }

    private func close(_ ids: [UUID]) {
        for id in ids {
            guard entries[id] != nil else { continue }
            forget(id)
            onClosed?(id)
        }
    }

    private func scheduleRefresh() {
        guard !pending, !stopped, !entries.isEmpty else { return }
        pending = true
        let token = generation
        Task { @MainActor [weak self] in
            // AX can announce a move before WindowServer commits its new CG bounds.
            // Coalesce the event burst once, then read the committed position.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !self.stopped, self.generation == token else { return }
            self.pending = false
            let pids = Set(self.entries.values.map { $0.anchor.processID }.filter { $0 > 0 })
            self.apply(self.backend.snapshot(processes: pids))
        }
    }

    private func apply(_ snapshot: ResultSourceSnapshot) {
        latestSnapshot = snapshot
        // Copy IDs because callbacks may synchronously forget a result or stop this observer.
        for id in Array(entries.keys) {
            guard !stopped, var entry = entries[id] else { continue }
            let anchor = entry.anchor
            var screenPoint = anchor.screenPoint
            var visible = !snapshot.hiddenProcesses.contains(anchor.processID)
            if let windowID = anchor.windowID {
                if let replacement = snapshot.windows[windowID], replacement.processID != anchor.processID {
                    // A live ID owned by a different PID proves the frozen window no longer exists.
                    close([id])
                    continue
                }
                if let window = snapshot.windows[windowID], window.processID == anchor.processID,
                   CaptureRules.finite(window.frame) {
                    visible = visible && window.onScreen
                    if let original = entry.originalFrame {
                        screenPoint.x += window.frame.minX - original.minX
                        screenPoint.y += window.frame.minY - original.minY
                    }
                } else {
                    // Missing/off-Space windows and reused IDs never imply confirmed closure.
                    visible = false
                }
            }
            let point = CaptureRules.presentationPoint(screenPoint, primaryHeight: snapshot.primaryHeight)
            let changed = entry.lastPoint != point || entry.lastVisible != visible
            entry.lastPoint = point; entry.lastVisible = visible
            entries[id] = entry
            if changed { onChange?(id, point, visible) }
        }
        synchronizeWatches(snapshot)
    }

    private func synchronizeWatches(_ snapshot: ResultSourceSnapshot? = nil) {
        let snapshot = snapshot ?? latestSnapshot
        let wanted = Set(entries.values.map { $0.anchor.processID }.filter { $0 > 0 })
        for pid in watched.subtracting(wanted) { backend.unwatch(pid) }
        watched = wanted
        guard started, !stopped else { return }
        for pid in wanted {
            var windows: [CGWindowID: CGRect] = [:]
            for entry in entries.values where entry.anchor.processID == pid {
                guard let id = entry.anchor.windowID else { continue }
                if let current = snapshot.windows[id], current.processID == pid {
                    windows[id] = current.frame
                } else if let frame = entry.originalFrame { windows[id] = frame }
#if PINPIN_APP_STORE
                if windows[id] == nil { windows[id] = .null } // Keep initially missing IDs for the next query.
#endif
            }
            backend.watch(pid, windows: windows)
        }
    }
}

#if PINPIN_APP_STORE
protocol ResultSourceCheckTimer: AnyObject {
    func cancel()
}

typealias ResultSourceCheckFactory = (TimeInterval, @escaping @MainActor () -> Void) -> ResultSourceCheckTimer
typealias ResultSourceSnapshotRead = @Sendable (Set<pid_t>, Set<CGWindowID>) -> ResultSourceSnapshot

/// Only IDs are sent to WindowServer. CFArray contains raw CGWindowID values, not NSNumber objects.
enum StoreWindowSnapshot {
    static func read(processes: Set<pid_t>, windows: Set<CGWindowID>) -> ResultSourceSnapshot {
        var result = ResultSourceSnapshot(primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        var pointers = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let ids = pointers.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil)! }
        let values: [[String: Any]] = windows.isEmpty ? [] : (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] ?? [])
        for item in values {
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let id = item[kCGWindowNumber as String] as? UInt32, windows.contains(id),
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), CaptureRules.finite(frame) else { continue }
            // Retain a different owner too: PID reuse is evidence that the original source closed.
            result.windows[id] = ResultSourceWindow(id: id, processID: pid, frame: frame,
                onScreen: item[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        for pid in processes where NSRunningApplication(processIdentifier: pid)?.isHidden == true {
            result.hiddenProcesses.insert(pid)
        }
        return result
    }
}

/// Runs on the existing main run loop; creating a watch never creates a thread.
private final class RunLoopResultSourceCheckTimer: ResultSourceCheckTimer {
    private let timer: Timer
    init(interval: TimeInterval, receive: @escaping @MainActor () -> Void) {
        timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { receive() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    func cancel() { timer.invalidate() }
    deinit { timer.invalidate() }
}
#endif

@MainActor final class SystemResultSourceBackend: ResultSourceBackend {
    private var receive: ((ResultSourceEvent) -> Void)?
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
#if PINPIN_APP_STORE
    private let checkFactory: ResultSourceCheckFactory
    private let snapshotReader: ResultSourceSnapshotRead
    private let snapshotQueue = DispatchQueue(label: "PinPin.source-windows", qos: .utility)
    private var checkTimer: ResultSourceCheckTimer?
    private var checkGeneration = UUID()
    private var snapshotGeneration = UUID()
    private var watchedWindows: [pid_t: Set<CGWindowID>] = [:]
    private var cachedSnapshot = ResultSourceSnapshot()
    private var queryRunning = false
    private var needsQuery = false
    var snapshotsAreDeferred: Bool { true }

    init(checkFactory: @escaping ResultSourceCheckFactory = { interval, receive in
        RunLoopResultSourceCheckTimer(interval: interval, receive: receive)
    }, snapshotReader: @escaping ResultSourceSnapshotRead = { StoreWindowSnapshot.read(processes: $0, windows: $1) }) {
        self.checkFactory = checkFactory
        self.snapshotReader = snapshotReader
    }
#else
    private var worker: ResultSourceAXWorker?
#endif
    private var tokens: [pid_t: UUID] = [:]

    func snapshot(processes: Set<pid_t>) -> ResultSourceSnapshot {
#if PINPIN_APP_STORE
        return cachedSnapshot
#else
        var result = ResultSourceSnapshot(primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        // .optionAll retains minimized and other-Space identities; onScreen only controls visibility.
        let values = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for item in values {
            // Keep owner identity even for a foreign PID: a recycled frozen window ID
            // must not be mistaken for a temporarily hidden original source. No titles or content.
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), CaptureRules.finite(frame) else { continue }
            result.windows[id] = ResultSourceWindow(id: id, processID: pid, frame: frame,
                onScreen: item[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        for pid in processes where NSRunningApplication(processIdentifier: pid)?.isHidden == true {
            result.hiddenProcesses.insert(pid)
        }
        return result
#endif
    }

    func start(_ receive: @escaping (ResultSourceEvent) -> Void) {
        guard self.receive == nil else { return }
        self.receive = receive
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(workspace, name) { [weak self] _ in self?.refresh() }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            self?.receive?(.terminated(pid))
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.refresh() }
#if PINPIN_APP_STORE
        if !tokens.isEmpty { startChecks(); requestSnapshot() }
#endif
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         body: @escaping @MainActor (Notification) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { body(note) }
        }
        notifications.append((center, observer))
    }

    private func refresh() {
#if PINPIN_APP_STORE
        requestSnapshot()
#else
        receive?(.refresh)
#endif
    }

    func watch(_ pid: pid_t, windows: [CGWindowID: CGRect]) {
        let token = tokens[pid] ?? UUID()
        tokens[pid] = token
#if PINPIN_APP_STORE
        let ids = Set(windows.keys)
        let changed = watchedWindows[pid] != ids
        watchedWindows[pid] = ids
        startChecks()
        if changed {
            snapshotGeneration = UUID()
            requestSnapshot()
        }
#else
        if worker == nil { worker = ResultSourceAXWorker() }
        worker?.watch(pid, token: token, windows: windows) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.tokens[pid] == token else { return }
                self.receive?(event)
            }
        }
#endif
    }

#if PINPIN_APP_STORE
    private func startChecks() {
        guard receive != nil, !tokens.isEmpty, checkTimer == nil,
              let interval = CapturePlatformPolicy.sourceWindowCheckInterval else { return }
        let generation = checkGeneration
        checkTimer = checkFactory(interval) { [weak self] in
            guard let self, self.checkGeneration == generation, !self.tokens.isEmpty else { return }
            self.requestSnapshot()
        }
    }

    private func requestSnapshot() {
        guard receive != nil, !tokens.isEmpty else { return }
        needsQuery = true
        guard !queryRunning else { return }
        queryRunning = true
        needsQuery = false
        let generation = snapshotGeneration
        let processes = Set(tokens.keys)
        let windows = Set(watchedWindows.values.flatMap { $0 })
        let read = snapshotReader
        snapshotQueue.async { [weak self] in
            let snapshot = read(processes, windows)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queryRunning = false
                guard self.receive != nil, !self.tokens.isEmpty else { return }
                if self.snapshotGeneration == generation {
                    self.cachedSnapshot = snapshot
                    // Reuse the observer's existing pending refresh coalescing.
                    self.receive?(.refresh)
                }
                if self.needsQuery { self.requestSnapshot() }
            }
        }
    }
#endif

    func unwatch(_ pid: pid_t) {
        tokens[pid] = nil
#if PINPIN_APP_STORE
        watchedWindows[pid] = nil
        snapshotGeneration = UUID()
        if tokens.isEmpty { cancelChecks() }
        else { requestSnapshot() }
#else
        worker?.unwatch(pid)
#endif
    }

#if PINPIN_APP_STORE
    private func cancelChecks() {
        checkGeneration = UUID()
        snapshotGeneration = UUID()
        needsQuery = false
        cachedSnapshot = ResultSourceSnapshot()
        checkTimer?.cancel()
        checkTimer = nil
    }
#endif

    func stop() {
        receive = nil
        for (center, observer) in notifications { center.removeObserver(observer) }
        notifications.removeAll()
        tokens.removeAll()
#if PINPIN_APP_STORE
        watchedWindows.removeAll()
        cancelChecks()
#else
        worker?.stop(); worker = nil
#endif
    }

    deinit {
        for (center, observer) in notifications { center.removeObserver(observer) }
#if PINPIN_APP_STORE
        checkTimer?.cancel()
#else
        worker?.stop()
#endif
    }
}

#if !PINPIN_APP_STORE
/// One serial run loop owns all AX elements, registrations and one observer per PID.
/// MainActor never waits for this thread, including shutdown of an unresponsive AX provider.
private final class ResultSourceAXWorker: @unchecked Sendable {
    private final class Watch {
        let pid: pid_t
        let token: UUID
        let app: AXUIElement
        let observer: AXObserver
        let emit: (ResultSourceEvent) -> Void
        var desired: [CGWindowID: CGRect] = [:]
        var windows: [(AXUIElement, CGWindowID)] = []
        var appNotifications: [CFString] = []
        init(pid: pid_t, token: UUID, app: AXUIElement, observer: AXObserver, emit: @escaping (ResultSourceEvent) -> Void) {
            self.pid = pid; self.token = token; self.app = app; self.observer = observer; self.emit = emit
        }
    }
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var commands: [() -> Void] = []
    private var stopping = false
    private var watches: [pid_t: Watch] = [:] // AX-thread confined.
    private var thread: Thread?
    private let windowNotifications = [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification,
                                       kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification] as [CFString]

    init() {
        let thread = Thread { [self] in run() }
        thread.name = "PinPin result source AX"
        self.thread = thread
        thread.start()
    }

    func watch(_ pid: pid_t, token: UUID, windows: [CGWindowID: CGRect], emit: @escaping (ResultSourceEvent) -> Void) {
        enqueue { [self] in
            if let old = watches[pid], old.token != token { remove(pid) }
            if watches[pid] == nil {
                var observer: AXObserver?
                guard AXObserverCreate(pid, { _, element, notification, context in
                    guard let context else { return }
                    Unmanaged<ResultSourceAXWorker>.fromOpaque(context).takeUnretainedValue().event(element, notification)
                }, &observer) == .success, let observer else { return }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                let watch = Watch(pid: pid, token: token, app: app, observer: observer, emit: emit)
                watches[pid] = watch
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] as [CFString] {
                    if AXObserverAddNotification(observer, app, name, Unmanaged.passUnretained(self).toOpaque()) == .success {
                        watch.appNotifications.append(name)
                    }
                }
            }
            guard let watch = watches[pid] else { return }
            // A same-frame update needs no new synchronous provider work.
            guard watch.desired != windows || watch.windows.isEmpty else { return }
            watch.desired = windows
            registerWindows(watch)
        }
    }

    func unwatch(_ pid: pid_t) { enqueue { [self] in remove(pid) } }

    func stop() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let finish = { [self] in
            for pid in Array(watches.keys) { remove(pid) }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        commands.append(finish)
        let current = loop
        lock.unlock()
        if let current { CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { [self] in drain() }; CFRunLoopWakeUp(current) }
    }

    private func enqueue(_ command: @escaping () -> Void) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        commands.append(command)
        let current = loop
        lock.unlock()
        if let current { CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { [self] in drain() }; CFRunLoopWakeUp(current) }
    }

    private func run() {
        let keepAlive = Port()
        RunLoop.current.add(keepAlive, forMode: .default)
        lock.lock(); loop = CFRunLoopGetCurrent(); lock.unlock()
        drain()
        lock.lock(); let shouldRun = !stopping; lock.unlock()
        if shouldRun { CFRunLoopRun() }
        // stop may arrive while the initial drain is blocked in AX RPC. Even when the
        // queued finish block never runs, all registrations must be removed on this AX thread.
        for pid in Array(watches.keys) { remove(pid) }
        lock.lock(); loop = nil; commands.removeAll(); lock.unlock()
        keepAlive.invalidate()
        thread = nil
    }

    private func drain() {
        lock.lock(); let work = commands; commands.removeAll(); lock.unlock()
        for command in work { command() }
    }

    private func remove(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        for (window, _) in watch.windows {
            for name in windowNotifications { AXObserverRemoveNotification(watch.observer, window, name) }
        }
        for name in watch.appNotifications { AXObserverRemoveNotification(watch.observer, watch.app, name) }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(watch.observer), .defaultMode)
    }

    private func registerWindows(_ watch: Watch) {
        // A minimized window may stop answering geometry. Keep its established binding so its
        // restore/destroy notifications still arrive; only forgotten IDs lose subscriptions here.
        for (window, id) in watch.windows where watch.desired[id] == nil {
            for name in windowNotifications { AXObserverRemoveNotification(watch.observer, window, name) }
        }
        watch.windows.removeAll { watch.desired[$0.1] == nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(watch.app, kAXWindowsAttribute as CFString, &raw) == .success,
              let candidates = raw as? [AXUIElement] else { return }
        var frames: [(AXUIElement, CGRect)] = []
        for window in candidates {
            AXUIElementSetMessagingTimeout(window, 0.2)
            guard let frame = frame(window) else { continue }
            frames.append((window, frame))
        }
        var next = watch.windows
        for (window, frame) in frames {
            if next.contains(where: { CFEqual($0.0, window) }) { continue }
            let matches = watch.desired.filter { $0.value == frame }
            // No private AXWindowID: bind only an unambiguous public AX/CG geometry pair.
            guard matches.count == 1, let id = matches.first?.key else { continue }
            guard !next.contains(where: { $0.1 == id }), frames.filter({ $0.1 == frame }).count == 1 else { continue }
            next.append((window, id))
        }
        for (window, _) in watch.windows where !next.contains(where: { CFEqual($0.0, window) }) {
            for name in windowNotifications { AXObserverRemoveNotification(watch.observer, window, name) }
        }
        for (window, _) in next where !watch.windows.contains(where: { CFEqual($0.0, window) }) {
            for name in windowNotifications { AXObserverAddNotification(watch.observer, window, name, Unmanaged.passUnretained(self).toOpaque()) }
        }
        watch.windows = next
    }

    private func frame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = unsafeBitCast(position, to: AXValue.self), s = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
        let rect = CGRect(origin: origin, size: dimensions)
        return CaptureRules.finite(rect) ? rect : nil
    }

    private func event(_ element: AXUIElement, _ notification: CFString) {
        // Destroyed AX elements may no longer answer even GetPid; retain their established identity.
        let known = watches.values.first { candidate in
            CFEqual(candidate.app, element) || candidate.windows.contains { CFEqual($0.0, element) }
        }
        var owner: pid_t = 0
        if known == nil {
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard AXUIElementGetPid(element, &owner) == .success else { return }
        }
        guard let watch = known ?? watches[owner] else { return }
        do {
            let associated = watch.windows.filter { CFEqual($0.0, element) }
            if (notification as String) == kAXUIElementDestroyedNotification {
                let ids = Set(associated.map { $0.1 })
                watch.windows.removeAll { CFEqual($0.0, element) }
                watch.emit(.destroyed(watch.pid, ids))
            } else {
                // Window-created callbacks supply the new window, not necessarily the app.
                watch.emit(.refresh)
            }
            if (notification as String) == kAXWindowCreatedNotification || (notification as String) == kAXFocusedWindowChangedNotification || (notification as String) == kAXMainWindowChangedNotification {
                registerWindows(watch)
            }
        }
    }
}
#endif
