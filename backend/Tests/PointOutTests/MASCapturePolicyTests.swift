import XCTest
@testable import PointOut

final class MASCapturePolicyTests: XCTestCase {
    func testBuildCapabilities() {
#if PINPIN_APP_STORE
        XCTAssertFalse(CapturePlatformPolicy.allowsAccessibilitySelection)
        XCTAssertEqual(CapturePlatformPolicy.sourceWindowCheckInterval, 0.250)
#else
        XCTAssertTrue(CapturePlatformPolicy.allowsAccessibilitySelection)
        XCTAssertNil(CapturePlatformPolicy.sourceWindowCheckInterval)
#endif
    }
}

#if PINPIN_APP_STORE
private final class CheckTimerSpy: ResultSourceCheckTimer {
    var cancellations = 0
    let fire: @MainActor () -> Void
    init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
    func cancel() { cancellations += 1 }
}

private final class SnapshotReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var active = 0
    private var maximumActive = 0
    private var usedMainThread = false
    let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }
    func unblock() { release.signal() }
    var calls: Int { lock.withLock { count } }
    var maximumConcurrent: Int { lock.withLock { maximumActive } }
    var readOnMainThread: Bool { lock.withLock { usedMainThread } }
    func read(_ processes: Set<pid_t>, _ windows: Set<CGWindowID>) -> ResultSourceSnapshot {
        let index = lock.withLock { () -> Int in
            count += 1; active += 1; maximumActive = max(maximumActive, active)
            usedMainThread = usedMainThread || Thread.isMainThread
            return count
        }
        if index == 1 {
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
        }
        lock.withLock { active -= 1 }
        return ResultSourceSnapshot(primaryHeight: CGFloat(index))
    }
}

@MainActor final class MASWindowCheckTests: XCTestCase {
    func testRealRunLoopTimerRefreshesAfterInitialRead() async {
        let refreshed = expectation(description: "initial read and real timer refresh")
        refreshed.expectedFulfillmentCount = 2
        let backend = SystemResultSourceBackend(snapshotReader: { _, _ in ResultSourceSnapshot() })
        var count = 0
        backend.start { event in
            if case .refresh = event, count < 2 { count += 1; refreshed.fulfill() }
        }
        backend.watch(getpid(), windows: [10: .zero])
        await fulfillment(of: [refreshed], timeout: 2)
        backend.stop()
    }

    func testNoWatchHasNoTimerAndManyWatchesShareOneUntilLastUnwatch() {
        var timers: [CheckTimerSpy] = []
        let backend = SystemResultSourceBackend(checkFactory: { interval, fire in
            XCTAssertEqual(interval, 0.250)
            let timer = CheckTimerSpy(fire); timers.append(timer); return timer
        }, snapshotReader: { _, _ in ResultSourceSnapshot() })
        backend.start { _ in }
        XCTAssertTrue(timers.isEmpty)
        for _ in 0..<64 { backend.watch(100, windows: [10: .zero]) }
        backend.watch(200, windows: [20: .zero])
        XCTAssertEqual(timers.count, 1)
        backend.unwatch(100)
        XCTAssertEqual(timers[0].cancellations, 0)
        backend.unwatch(200)
        XCTAssertEqual(timers[0].cancellations, 1)
        timers[0].fire()
        backend.stop()
        XCTAssertEqual(timers[0].cancellations, 1)
    }

    func testSixtyFourWatchesAndTimerBurstKeepOneReadInFlightAndMainThreadAvailable() async {
        let gate = SnapshotReadGate(started: expectation(description: "background read blocked"))
        var timer: CheckTimerSpy?
        let backend = SystemResultSourceBackend(checkFactory: { _, fire in
            let value = CheckTimerSpy(fire); timer = value; return value
        }, snapshotReader: { gate.read($0, $1) })
        let refreshed = expectation(description: "one read and one coalesced followup")
        refreshed.expectedFulfillmentCount = 2
        backend.start { if case .refresh = $0 { refreshed.fulfill() } }
        backend.watch(100, windows: [10: .zero])
        await fulfillment(of: [gate.started], timeout: 1)
        for _ in 0..<64 { backend.watch(100, windows: [10: .zero]) }
        for _ in 0..<100 { timer?.fire() }
        // This synchronous main-actor call must return while the reader is still blocked.
        XCTAssertTrue(backend.snapshot(processes: [100]).windows.isEmpty)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertFalse(gate.readOnMainThread)
        gate.unblock()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(gate.maximumConcurrent, 1)
        backend.stop()
    }

    func testStopRestartRejectsOldQueryAndOldTimer() async {
        let gate = SnapshotReadGate(started: expectation(description: "old query blocked"))
        var timers: [CheckTimerSpy] = []
        let backend = SystemResultSourceBackend(checkFactory: { _, fire in
            let timer = CheckTimerSpy(fire); timers.append(timer); return timer
        }, snapshotReader: { gate.read($0, $1) })
        backend.start { _ in XCTFail("stopped callback") }
        backend.watch(100, windows: [10: .zero])
        await fulfillment(of: [gate.started], timeout: 1)
        backend.stop()
        XCTAssertEqual(timers[0].cancellations, 1)
        let published = expectation(description: "new generation published")
        backend.start { if case .refresh = $0 { published.fulfill() } }
        backend.watch(200, windows: [20: .zero])
        timers[0].fire()
        XCTAssertEqual(timers.count, 2)
        gate.unblock()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(backend.snapshot(processes: [200]).primaryHeight, 2)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(gate.maximumConcurrent, 1)
        backend.stop()
        XCTAssertEqual(timers[1].cancellations, 1)
    }

    func testLastUnwatchRejectsLateQueryAndStopsFurtherWork() async {
        let gate = SnapshotReadGate(started: expectation(description: "query blocked"))
        var timer: CheckTimerSpy?
        let backend = SystemResultSourceBackend(checkFactory: { _, fire in
            let value = CheckTimerSpy(fire); timer = value; return value
        }, snapshotReader: { gate.read($0, $1) })
        let publication = expectation(description: "no publication after unwatch")
        publication.isInverted = true
        backend.start { if case .refresh = $0 { publication.fulfill() } }
        backend.watch(100, windows: [10: .zero])
        await fulfillment(of: [gate.started], timeout: 1)
        timer?.fire() // Mark a followup while the first query is blocked.
        backend.unwatch(100)
        gate.unblock()
        timer?.fire()
        await fulfillment(of: [publication], timeout: 0.15)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(timer?.cancellations, 1)
        XCTAssertTrue(backend.snapshot(processes: [100]).windows.isEmpty)
        backend.stop()
    }

    func testObserverLastResultForgetImmediatelyCancelsSharedTimer() {
        var timers: [CheckTimerSpy] = []
        let backend = SystemResultSourceBackend(checkFactory: { _, fire in
            let timer = CheckTimerSpy(fire); timers.append(timer); return timer
        }, snapshotReader: { _, _ in ResultSourceSnapshot() })
        let observer = WindowResultObserver(backend: backend)
        let anchors = (0..<64).map { _ in
            TargetAnchor(id: UUID(), screenPoint: .zero, presentationPoint: .zero,
                         processID: getpid(), startedAt: 0, windowID: 10)
        }
        XCTAssertTrue(timers.isEmpty)
        anchors.forEach(observer.track)
        XCTAssertEqual(timers.count, 1)
        anchors.dropLast().forEach { observer.forget($0.id) }
        XCTAssertEqual(timers[0].cancellations, 0)
        observer.forget(anchors.last!.id)
        XCTAssertEqual(timers[0].cancellations, 1)
        observer.stop()
    }

    func testDeinitReleasesTimerAndDoesNotWaitForRunningQuery() async {
        let gate = SnapshotReadGate(started: expectation(description: "query blocked"))
        weak var released: SystemResultSourceBackend?
        var timer: CheckTimerSpy?
        var backend: SystemResultSourceBackend? = SystemResultSourceBackend(checkFactory: { _, fire in
            let value = CheckTimerSpy(fire); timer = value; return value
        }, snapshotReader: { gate.read($0, $1) })
        released = backend
        backend?.start { _ in XCTFail("released backend published") }
        backend?.watch(100, windows: [10: .zero])
        await fulfillment(of: [gate.started], timeout: 1)
        backend = nil
        XCTAssertNil(released)
        XCTAssertEqual(timer?.cancellations, 1)
        gate.unblock()
        timer?.fire()
    }

    func testDeferredFirstSnapshotUsesTriggerFrameForMovement() async {
        let backend = SystemResultSourceBackend(checkFactory: { _, fire in CheckTimerSpy(fire) }, snapshotReader: { processes, windows in
            XCTAssertEqual(processes, [100]); XCTAssertEqual(windows, [10])
            return ResultSourceSnapshot(windows: [10: ResultSourceWindow(id: 10, processID: 100,
                frame: CGRect(x: 150, y: 160, width: 600, height: 400), onScreen: true)], primaryHeight: 1000)
        })
        let observer = WindowResultObserver(backend: backend)
        let visible = expectation(description: "moved source visible")
        observer.onChange = { _, point, shown in
            if shown { XCTAssertEqual(point, CGPoint(x: 230, y: 780)); visible.fulfill() }
        }
        observer.track(TargetAnchor(id: UUID(), screenPoint: CGPoint(x: 180, y: 260),
            presentationPoint: CGPoint(x: 180, y: 740), processID: 100, startedAt: 0, windowID: 10,
            windowFrame: CGRect(x: 100, y: 200, width: 600, height: 400)))
        await fulfillment(of: [visible], timeout: 1)
        observer.stop()
    }

    func testDeferredUnknownFrameRetainsAnchorAndForeignPIDCloses() async {
        for foreign in [false, true] {
            let backend = SystemResultSourceBackend(checkFactory: { _, fire in CheckTimerSpy(fire) }, snapshotReader: { _, windows in
                XCTAssertEqual(windows, [10])
                return ResultSourceSnapshot(windows: [10: ResultSourceWindow(id: 10, processID: foreign ? 999 : 100,
                    frame: CGRect(x: 900, y: 800, width: 600, height: 400), onScreen: true)], primaryHeight: 1000)
            })
            let observer = WindowResultObserver(backend: backend)
            let done = expectation(description: foreign ? "foreign source closed" : "unknown origin preserved")
            let id = UUID()
            observer.onChange = { _, point, visible in
                if visible { XCTAssertFalse(foreign); XCTAssertEqual(point, CGPoint(x: 180, y: 740)); done.fulfill() }
            }
            observer.onClosed = { closed in XCTAssertTrue(foreign); XCTAssertEqual(closed, id); done.fulfill() }
            observer.track(TargetAnchor(id: id, screenPoint: CGPoint(x: 180, y: 260),
                presentationPoint: CGPoint(x: 180, y: 740), processID: 100, startedAt: 0, windowID: 10))
            await fulfillment(of: [done], timeout: 1)
            observer.stop()
        }
    }
}
#endif
