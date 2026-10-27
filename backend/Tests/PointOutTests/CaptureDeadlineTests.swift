import Foundation
import XCTest
@testable import PointOut

final class CaptureDeadlineTests: XCTestCase {
    func testOneDeadlineIncludesPreparationAndSubsequentRead() async {
        let worker = DispatchQueue(label: "PointOutTests.capture-deadline")
        let result = await boundedCapture(timeout: 0.04, fallback: "timeout", cancelled: "cancelled") { completion in
            // Metadata and the following read are one operation, with no fresh per-stage deadline.
            worker.asyncAfter(deadline: .now() + 0.025) {
                worker.asyncAfter(deadline: .now() + 0.025) { completion.finish("late success") }
            }
        }
        XCTAssertEqual(result, "timeout")
    }

    func testCancellationDuringPreparationReturnsCancellationInsteadOfLateRead() async {
        var started: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { started = $0 }
        let task = Task {
            await boundedCapture(timeout: 1, fallback: "timeout", cancelled: "cancelled") { completion in
                started.yield(())
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { completion.finish("late success") }
            }
        }
        for await _ in stream.prefix(1) { break }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
        started.finish()
    }
}

/// Local backend state only: this fixture never checks or claims real system permission.
private final class TimeoutCapabilityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    func setAllowed(_ value: Bool) { lock.withLock { allowed = value } }
    func snapshot() -> CapturedContext {
        var context = CapturedContext(sessionID: UUID(), targetText: "", surroundingText: "", appName: "",
                                      windowTitle: "", source: "ax_timeout")
        context.canCaptureVisual = lock.withLock { allowed }
        return context
    }
    func cancelled() -> CapturedContext {
        var context = snapshot()
        context.source = "cancelled"
        context.canCaptureVisual = false
        return context
    }
}

extension CaptureDeadlineTests {
    func testTimeoutReadsCapabilityPreparedAfterOperationStarted() async {
        let state = TimeoutCapabilityFixture()
        let result = await boundedCapture(timeout: 0.03, fallback: state.snapshot(), cancelled: state.cancelled()) { _ in
            state.setAllowed(true)
            // AX does not finish. The timeout must consult completed preparation, not its entry state.
        }
        XCTAssertEqual(result.source, "ax_timeout")
        XCTAssertTrue(result.canCaptureVisual)
    }

    func testKnownSecureRevocationRemainsDisabledAtTimeout() async {
        let state = TimeoutCapabilityFixture()
        state.setAllowed(true)
        let result = await boundedCapture(timeout: 0.03, fallback: state.snapshot(), cancelled: state.cancelled()) { _ in
            // Mirrors capability revocation after a secure element is identified, before deadline.
            state.setAllowed(false)
        }
        XCTAssertFalse(result.canCaptureVisual)
    }

    func testCancellationDoesNotRestorePreparedVisualCapability() async {
        let state = TimeoutCapabilityFixture()
        var started: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { started = $0 }
        let task = Task {
            await boundedCapture(timeout: 0.3, fallback: state.snapshot(), cancelled: state.cancelled()) { _ in
                state.setAllowed(true)
                started.yield(())
            }
        }
        for await _ in stream.prefix(1) { break }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.source, "cancelled")
        XCTAssertFalse(result.canCaptureVisual)
        started.finish()
    }

    func testSlowSourceValidationCannotStartAcquisitionAfterDeadline() async {
        let worker = DispatchQueue(label: "PointOutTests.slow-source-validation")
        var finished: AsyncStream<Bool>.Continuation!
        let stream = AsyncStream<Bool> { finished = $0 }
        let result = await boundedCapture(timeout: 0.03, fallback: "visual_timeout", cancelled: "cancelled") { completion in
            worker.asyncAfter(deadline: .now() + 0.08) {
                // A source/window call may finish late; the next acquisition must still be skipped.
                let wouldStartAcquisition = !completion.isFinished
                if wouldStartAcquisition { completion.finish("must not capture") }
                finished.yield(wouldStartAcquisition)
                finished.finish()
            }
        }
        XCTAssertEqual(result, "visual_timeout")
        for await acquisitionStarted in stream { XCTAssertFalse(acquisitionStarted) }
    }
}
