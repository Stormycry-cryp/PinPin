import XCTest
@testable import PointOut

@MainActor private final class FakeResultSourceBackend: ResultSourceBackend {
    var value = ResultSourceSnapshot(primaryHeight: 1000)
    var receive: ((ResultSourceEvent) -> Void)?
    var active: [pid_t: [CGWindowID: CGRect]] = [:]
    var starts = 0
    var stops = 0
    var snapshots = 0
    var onSnapshot: (() -> Void)?
    var startCallbacks: [(ResultSourceEvent) -> Void] = []
    func snapshot(processes: Set<pid_t>) -> ResultSourceSnapshot { snapshots += 1; onSnapshot?(); return value }
    func start(_ receive: @escaping (ResultSourceEvent) -> Void) {
        starts += 1; self.receive = receive; startCallbacks.append(receive)
    }
    func watch(_ pid: pid_t, windows: [CGWindowID: CGRect]) { active[pid] = windows }
    func unwatch(_ pid: pid_t) { active[pid] = nil }
    func stop() { stops += 1; receive = nil; active.removeAll() }
    func put(_ id: CGWindowID = 10, pid: pid_t = 100, frame: CGRect = CGRect(x: 100, y: 200, width: 600, height: 400), visible: Bool = true) {
        value.windows[id] = ResultSourceWindow(id: id, processID: pid, frame: frame, onScreen: visible)
    }
}

@MainActor final class ResultSourceObserverTests: XCTestCase {
    private func anchor(id: UUID = UUID(), pid: pid_t = 100, window: CGWindowID? = 10,
                        screenPoint: CGPoint = CGPoint(x: 180, y: 260)) -> TargetAnchor {
        TargetAnchor(id: id, screenPoint: screenPoint,
                     presentationPoint: CaptureRules.presentationPoint(screenPoint, primaryHeight: 1000),
                     processID: pid, startedAt: 1, windowID: window)
    }

    private func flush(_ source: WindowResultObserver, backend: FakeResultSourceBackend) async {
        let done = expectation(description: "coalesced source refresh")
        let before = backend.snapshots
        backend.onSnapshot = { done.fulfill() }
        backend.receive?(.refresh)
        await fulfillment(of: [done], timeout: 1)
        backend.onSnapshot = nil
        XCTAssertEqual(backend.snapshots, before + 1)
    }

    func testAbsoluteProjectionDoesNotAccumulateMoveAndHandlesScreenHeight() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        var output: [(CGPoint, Bool)] = []
        source.onChange = { _, point, visible in output.append((point, visible)) }
        source.track(anchor())
        XCTAssertEqual(output.last?.0, CGPoint(x: 180, y: 740))
        backend.put(frame: CGRect(x: -500, y: -100, width: 600, height: 400))
        await flush(source, backend: backend)
        XCTAssertEqual(output.last?.0, CGPoint(x: -420, y: 1040))
        let count = output.count
        await flush(source, backend: backend)
        XCTAssertEqual(output.count, count)
        backend.value.primaryHeight = 1200
        await flush(source, backend: backend)
        XCTAssertEqual(output.last?.0, CGPoint(x: -420, y: 1240))
        source.stop()
    }

    func testMinimizeSpaceMissingAndHiddenRetainResultThenRestore() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        let item = anchor()
        var visible: [Bool] = [], closed: [UUID] = []
        source.onChange = { _, _, value in visible.append(value) }
        source.onClosed = { closed.append($0) }
        source.track(item)
        backend.put(visible: false)
        await flush(source, backend: backend)
        XCTAssertEqual(visible.last, false)
        backend.value.windows.removeAll()
        await flush(source, backend: backend)
        XCTAssertTrue(closed.isEmpty)
        backend.put(); backend.value.hiddenProcesses.insert(100)
        await flush(source, backend: backend)
        XCTAssertEqual(visible.last, false)
        backend.value.hiddenProcesses.removeAll()
        await flush(source, backend: backend)
        XCTAssertEqual(visible.last, true)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(backend.active.count, 1)
        source.stop()
    }

    func testUnknownWindowKeepsCGOriginButReprojectsForNewPrimaryScreen() async {
        let backend = FakeResultSourceBackend()
        let source = WindowResultObserver(backend: backend)
        var points: [CGPoint] = []
        source.onChange = { _, point, _ in points.append(point) }
        source.track(anchor(window: nil, screenPoint: CGPoint(x: -1400, y: 80)))
        backend.value.primaryHeight = 1500
        await flush(source, backend: backend)
        XCTAssertEqual(points.last, CGPoint(x: -1400, y: 1420))
        source.stop()
    }

    func testInitiallyUnavailableFrameDoesNotInventMovementWhenItReappears() async {
        let backend = FakeResultSourceBackend()
        let source = WindowResultObserver(backend: backend)
        var last = CGPoint.zero
        source.onChange = { _, point, _ in last = point }
        source.track(anchor())
        backend.put(frame: CGRect(x: 900, y: 800, width: 600, height: 400))
        await flush(source, backend: backend)
        XCTAssertEqual(last, CGPoint(x: 180, y: 740))
        source.stop()
    }

    func testReusedWindowIDClosesOriginalInsteadOfFollowingOtherPID() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        let item = anchor()
        var closed: [UUID] = []
        source.onClosed = { closed.append($0) }
        source.track(item)
        backend.put(pid: 999)
        // Use explicit completion because the last closure tears down this backend.
        let done = expectation(description: "original source closed")
        source.onClosed = { closed.append($0); done.fulfill() }
        backend.receive?(.refresh)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(closed, [item.id])
        XCTAssertTrue(backend.active.isEmpty)
        source.stop()
    }

    func testSixtyFourResultsShareOnePIDWatchAndLastForgetReleasesBackend() {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        let items = (0..<64).map { _ in anchor() }
        items.forEach(source.track)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.active.count, 1)
        XCTAssertEqual(backend.active[100]?.count, 1)
        items.dropLast().forEach { source.forget($0.id) }
        XCTAssertEqual(backend.stops, 0)
        source.forget(items.last!.id)
        XCTAssertTrue(backend.active.isEmpty)
        XCTAssertEqual(backend.stops, 1)
        source.stop()
    }

    func testForgetAndNewTrackRejectOldLifecycleEvents() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        let old = anchor(), new = anchor()
        var closed: [UUID] = []
        source.onClosed = { closed.append($0) }
        source.track(old)
        let delayed = backend.startCallbacks[0]
        backend.receive?(.refresh)
        source.forget(old.id)
        source.track(new)
        let before = backend.snapshots
        delayed(.destroyed(100, [10]))
        delayed(.terminated(100))
        await Task.yield()
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(backend.snapshots, before)
        XCTAssertEqual(backend.active.count, 1)
        source.stop()
    }

    func testConfirmedDestructionOnlyClosesMatchingWindowAndPID() {
        let backend = FakeResultSourceBackend(); backend.put(); backend.put(20)
        let source = WindowResultObserver(backend: backend)
        let first = anchor(), second = anchor(window: 20)
        var closed: [UUID] = []
        source.onClosed = { closed.append($0) }
        source.track(first); source.track(second)
        backend.receive?(.destroyed(999, [10]))
        XCTAssertTrue(closed.isEmpty)
        backend.receive?(.destroyed(100, [10]))
        XCTAssertEqual(closed, [first.id])
        XCTAssertEqual(backend.active[100]?.keys.sorted(), [20])
        backend.receive?(.terminated(100))
        XCTAssertEqual(Set(closed), Set([first.id, second.id]))
        source.stop()
    }

    func testStopIgnoresLatePendingEventsAndCannotRestart() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        var count = 0
        source.onChange = { _, _, _ in count += 1 }
        source.onClosed = { _ in XCTFail("closed after stop") }
        source.track(anchor())
        let delayed = backend.startCallbacks[0]
        backend.receive?(.refresh)
        source.stop()
        delayed(.terminated(100)); delayed(.refresh)
        source.track(anchor())
        await Task.yield()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertTrue(backend.active.isEmpty)
    }

    func testNotificationBurstUsesOnePendingRefreshAndCallbacksMayForget() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        let item = anchor()
        source.track(item)
        let before = backend.snapshots
        let done = expectation(description: "burst refreshed once")
        backend.onSnapshot = { done.fulfill() }
        source.onChange = { id, _, _ in source.forget(id) }
        backend.put(frame: CGRect(x: 101, y: 200, width: 600, height: 400))
        for _ in 0..<100 { backend.receive?(.refresh) }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(backend.snapshots, before + 1)
        XCTAssertTrue(backend.active.isEmpty)
        source.stop()
    }

    func testMoveNotificationBeforeWindowServerCommitUsesSettledBounds() async {
        let backend = FakeResultSourceBackend(); backend.put()
        let source = WindowResultObserver(backend: backend)
        var point = CGPoint.zero
        source.onChange = { _, value, _ in point = value }
        source.track(anchor())
        let done = expectation(description: "committed window position")
        backend.onSnapshot = { done.fulfill() }
        backend.receive?(.refresh)
        // The public AX event precedes the new bounds, without a second notification.
        try? await Task.sleep(for: .milliseconds(20))
        backend.put(frame: CGRect(x: 143, y: 173, width: 600, height: 400))
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(point, CGPoint(x: 223, y: 767))
        backend.onSnapshot = nil
        source.stop()
    }
}
