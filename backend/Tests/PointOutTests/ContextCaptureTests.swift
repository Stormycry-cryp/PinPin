import XCTest
import CoreGraphics
@testable import PointOut

private actor SnapshotCounter {
    var calls = 0
    func next() -> Int { calls += 1; return calls }
}

#if PINPIN_APP_STORE
private final class WeakCapturedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: ContextCapture.Frame?
    var value: ContextCapture.Frame? { lock.withLock { stored } }
    func set(_ frame: ContextCapture.Frame) { lock.withLock { stored = frame } }
}
#endif

final class ContextCaptureTests: XCTestCase {
    private func anchor() -> TargetAnchor {
        TargetAnchor(id: UUID(), screenPoint: CGPoint(x: -400, y: 100),
                     presentationPoint: CGPoint(x: -400, y: 800), processID: 42, startedAt: 0)
    }
    private func context(_ anchor: TargetAnchor, text: String = "", source: String = "selection_unavailable") -> CapturedContext {
        CapturedContext(sessionID: anchor.id, targetText: text, surroundingText: "", appName: "Fixture", windowTitle: "", source: source)
    }
    private func capture(counter: SnapshotCounter, text: String = "", source: String = "selection_unavailable", permission: Bool = true) -> ContextCapture {
        let blank: @Sendable (TargetAnchor) async -> CapturedContext = { anchor in
            CapturedContext(sessionID: anchor.id, targetText: text, surroundingText: "", appName: "Fixture", windowTitle: "", source: source)
        }
        return ContextCapture(selectionProbe: blank, snapshotProvider: { anchor in
            let count = await counter.next()
            let canvas = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(gray: CGFloat(count) / 10, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            return ContextCapture.Snapshot(frame: ContextCapture.Frame(image: canvas.makeImage()!, bounds: CGRect(x: -600, y: 0, width: 1200, height: 800), point: anchor.screenPoint), source: "visual_ready")
        }, screenCaptureAllowed: { permission })
    }
    func testCancelledInitialCaptureDoesNotQueryAnyProvider() async {
        let a = anchor(), counter = SnapshotCounter()
        let subject = capture(counter: counter)
        let task = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); return await subject.capture(a) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.source, "cancelled"); XCTAssertNil(result.imageData)
        let calls = await counter.calls; XCTAssertEqual(calls, 0)
    }
    func testSameFrameExpandsOnceWithoutRecaptureOrTextRecognition() async throws {
        let a = anchor(), counter = SnapshotCounter(), subject = capture(counter: counter)
        let local = await subject.capture(a)
        XCTAssertEqual(local.source, "visual_local"); XCTAssertTrue(local.targetText.isEmpty)
        XCTAssertNotNil(local.originalImageData); XCTAssertNotEqual(local.originalImageData, local.imageData)
        XCTAssertTrue(local.canExpandVisual)
        let expanded = await subject.supplement(local, anchor: a, plan: .expandVisual)
        XCTAssertEqual(expanded.source, "visual_window"); XCTAssertFalse(expanded.canExpandVisual)
        XCTAssertEqual(expanded.pointInImage?.x ?? -1, 1.0 / 6, accuracy: 0.001)
        XCTAssertEqual(expanded.pointInImage?.y ?? -1, 0.125, accuracy: 0.001)
        XCTAssertNotEqual(expanded.imageData, local.imageData)
        let repeatAttempt = await subject.supplement(local, anchor: a, plan: .expandVisual)
        XCTAssertEqual(repeatAttempt.imageData, local.imageData)
        let calls = await counter.calls; XCTAssertEqual(calls, 1)
    }
    func testUseCurrentAndForgetReleaseFrozenFrame() async {
        let a = anchor(), counter = SnapshotCounter(), subject = capture(counter: counter)
        let local = await subject.capture(a)
        _ = await subject.supplement(local, anchor: a, plan: .useCurrent)
        let afterConsumed = await subject.supplement(local, anchor: a, plan: .expandVisual)
        XCTAssertEqual(afterConsumed.source, "visual_local")
        let b = anchor(), other = await subject.capture(b)
        subject.forget(b.id)
        let afterForgotten = await subject.supplement(other, anchor: b, plan: .expandVisual)
        XCTAssertEqual(afterForgotten.source, "visual_local")
    }
#if !PINPIN_APP_STORE
    func testExplicitSelectionRemainsExactWhenOptionalImageIsAttached() async {
        let a = anchor(), subject = capture(counter: SnapshotCounter(), text: "明确选区🧪", source: "ax_selection")
        let initial = await subject.capture(a)
        XCTAssertNil(initial.imageData); XCTAssertEqual(initial.targetText, "明确选区🧪")
        let supplemented = await subject.supplement(initial, anchor: a, plan: .selectionContext)
        XCTAssertEqual(supplemented.targetText, "明确选区🧪")
        XCTAssertEqual(supplemented.source, "ax_selection+visual"); XCTAssertNotNil(supplemented.imageData)
    }
#endif

    func testOtherSessionCannotConsumeFrame() async {
        let a = anchor(), subject = capture(counter: SnapshotCounter())
        let local = await subject.capture(a)
        let wrong = await subject.supplement(local, anchor: anchor(), plan: .expandVisual)
        XCTAssertEqual(wrong.imageData, local.imageData)
        let correct = await subject.supplement(local, anchor: a, plan: .expandVisual)
        XCTAssertEqual(correct.source, "visual_window")
    }
#if !PINPIN_APP_STORE
    func testSecureContextNeverReleasesAnImage() async {
        let a = anchor(), subject = capture(counter: SnapshotCounter(), source: "ax_secure_content")
        let initial = await subject.capture(a)
        XCTAssertNil(initial.imageData)
        let later = await subject.supplement(initial, anchor: a, plan: .expandVisual)
        XCTAssertNil(later.imageData)
    }
#endif

    func testPermissionRevocationWhileSnapshotPendingRemainsTyped() async {
        let a = anchor()
        let subject = ContextCapture(selectionProbe: { anchor in
            CapturedContext(sessionID: anchor.id, targetText: "", surroundingText: "", appName: "", windowTitle: "", source: "selection_unavailable")
        }, snapshotProvider: { _ in ContextCapture.Snapshot(source: "screen_permission_denied") }, screenCaptureAllowed: { true })
        let result = await subject.capture(a)
        XCTAssertTrue(result.screenCapturePermissionMissing); XCTAssertNil(result.imageData)
    }
#if PINPIN_APP_STORE
    func testStoreForgetAndExpansionReleaseFrozenBitmap() async {
        for expand in [false, true] {
            let frameReference = WeakCapturedFrame(), a = anchor()
            let subject = ContextCapture(snapshotProvider: { anchor in
                let canvas = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let frame = ContextCapture.Frame(image: canvas.makeImage()!,
                    bounds: CGRect(x: -600, y: 0, width: 1200, height: 800), point: anchor.screenPoint)
                frameReference.set(frame)
                return ContextCapture.Snapshot(frame: frame, source: "visual_ready")
            }, screenCaptureAllowed: { true })
            let context = await subject.capture(a)
            XCTAssertNotNil(frameReference.value)
            if expand { _ = await subject.supplement(context, anchor: a, plan: .expandVisual) }
            else { subject.forget(a.id) }
            XCTAssertNil(frameReference.value)
        }
    }

    func testStoreNeverInvokesInjectedSelectionProbeAndEncodesVisualEvidence() async {
        let counter = SnapshotCounter(), probeCounter = SnapshotCounter(), a = anchor()
        let subject = ContextCapture(selectionProbe: { anchor in
            _ = await probeCounter.next()
            return CapturedContext(sessionID: anchor.id, targetText: "must not read", surroundingText: "",
                                   appName: "", windowTitle: "", source: "ax_selection")
        }, snapshotProvider: { anchor in
            _ = await counter.next()
            let canvas = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            return ContextCapture.Snapshot(frame: ContextCapture.Frame(image: canvas.makeImage()!,
                bounds: CGRect(x: -600, y: 0, width: 1200, height: 800), point: anchor.screenPoint), source: "visual_ready")
        }, screenCaptureAllowed: { true })
        let local = await subject.capture(a)
        XCTAssertEqual(local.sessionID, a.id)
        XCTAssertTrue(local.targetText.isEmpty)
        XCTAssertEqual(local.source, "visual_local")
        XCTAssertNotNil(local.imageData)
        let expanded = await subject.supplement(local, anchor: a, plan: .expandVisual)
        XCTAssertEqual(expanded.source, "visual_window")
        XCTAssertNotEqual(local.imageData, expanded.imageData)
        let probes = await probeCounter.calls, snapshots = await counter.calls
        XCTAssertEqual(probes, 0); XCTAssertEqual(snapshots, 1)
    }

    func testStoreCancellationCancelsPendingFrameAndCannotExpandIt() async {
        let started = expectation(description: "snapshot started")
        let cancelled = expectation(description: "snapshot cancelled")
        let a = anchor()
        let subject = ContextCapture(selectionProbe: { _ in
            XCTFail("Store selection probe must not run")
            fatalError("unreachable")
        }, snapshotProvider: { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return ContextCapture.Snapshot(source: "cancelled")
        }, screenCaptureAllowed: { true })
        let task = Task { await subject.capture(a) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(result.source, "cancelled")
        XCTAssertNil(result.imageData)
        let expanded = await subject.supplement(result, anchor: a, plan: .expandVisual)
        XCTAssertNil(expanded.imageData)
        XCTAssertEqual(expanded.source, "cancelled")
    }
#endif
}
