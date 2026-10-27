import CoreGraphics
import XCTest
@testable import PointOut

final class NativeGestureRoutingTests: XCTestCase {
    private let origin = CGPoint(x: -220, y: 120)

    private func send(_ input: GestureStateMachine.Input, state: inout GestureStateMachine,
                      at point: CGPoint, time: TimeInterval) -> (GestureStateMachine.Decision, NativeGestureSample?) {
        let owned = state.ownsButton
        let decision = state.handle(input)
        return (decision, GlobalGestureMonitor.nativeSample(input: input, decision: decision,
                                                            wasOwned: owned, point: point, time: time))
    }

    func testTwoOwnedClicksKeepOneSessionAndOriginalCGCoordinates() {
        var state = GestureStateMachine()
        let first = send(.down(option: true), state: &state, at: origin, time: 1)
        guard case let .down(point, time, starts)? = first.1 else { return XCTFail("Missing owned down") }
        XCTAssertEqual(point, origin); XCTAssertEqual(time, 1); XCTAssertTrue(starts)
        XCTAssertEqual(first.0.actions, [.began])
        let up = send(.up, state: &state, at: origin, time: 1.05)
        guard case .up? = up.1 else { return XCTFail("Missing matching release") }
        XCTAssertTrue(up.0.swallow); XCTAssertTrue(state.wheelOpen)
        let next = CGPoint(x: -218, y: 121)
        let second = send(.down(option: true), state: &state, at: next, time: 1.1)
        guard case let .down(point2, time2, starts2)? = second.1 else { return XCTFail("Missing second down") }
        XCTAssertEqual(point2, next); XCTAssertEqual(time2, 1.1); XCTAssertFalse(starts2)
        XCTAssertEqual(second.0.actions, [.moved])
        XCTAssertTrue(state.wheelOpen)
    }

    func testDuplicateDownDoesNotRestartRecognizerOrSession() {
        var state = GestureStateMachine()
        _ = send(.down(option: true), state: &state, at: origin, time: 1)
        let duplicate = send(.down(option: true), state: &state, at: .zero, time: 1.01)
        XCTAssertTrue(duplicate.0.swallow)
        XCTAssertTrue(duplicate.0.actions.isEmpty)
        XCTAssertNil(duplicate.1)
    }

    func testUnownedMouseEventsOnlyResetAndRemainPassThrough() {
        var state = GestureStateMachine()
        for input in [GestureStateMachine.Input.down(option: false), .dragged, .up] {
            let result = send(input, state: &state, at: origin, time: 1)
            XCTAssertFalse(result.0.swallow)
            guard case .reset? = result.1 else { return XCTFail("Unowned input leaked to recognizer") }
        }
    }

    func testOptionReleaseAndEscapeResetButStillSwallowTheirPairedUp() {
        for cancel in [GestureStateMachine.Input.optionReleased, .escape] {
            var state = GestureStateMachine()
            _ = send(.down(option: true), state: &state, at: origin, time: 1)
            let result = send(cancel, state: &state, at: origin, time: 1.01)
            guard case .reset? = result.1 else { return XCTFail("Missing reset") }
            XCTAssertEqual(result.0.actions, [.closed])
            let release = send(.up, state: &state, at: origin, time: 1.02)
            XCTAssertTrue(release.0.swallow)
            XCTAssertTrue(release.0.actions.isEmpty)
            guard case .reset? = release.1 else { return XCTFail("Cancelled paired up must not recognize a clear") }
            XCTAssertFalse(send(.up, state: &state, at: origin, time: 1.03).0.swallow)
        }
    }

    func testInterruptedTapResetsRecognitionAndDoesNotOwnLaterOrdinaryClick() {
        var state = GestureStateMachine()
        _ = send(.down(option: true), state: &state, at: origin, time: 1)
        let interrupted = send(.interrupted(buttonIsDown: false), state: &state, at: origin, time: 1.01)
        guard case .reset? = interrupted.1 else { return XCTFail("Missing interrupted reset") }
        XCTAssertFalse(state.ownsButton)
        XCTAssertFalse(send(.down(option: false), state: &state, at: origin, time: 2).0.swallow)
        XCTAssertFalse(send(.up, state: &state, at: origin, time: 2.05).0.swallow)
    }

    func testOwnedDragPassesOnlyActualCGPosition() {
        var state = GestureStateMachine()
        _ = send(.down(option: true), state: &state, at: origin, time: 1)
        let point = CGPoint(x: -110, y: -420)
        let dragged = send(.dragged, state: &state, at: point, time: 1.01)
        guard case .dragged(let actual)? = dragged.1 else { return XCTFail("Missing owned drag") }
        XCTAssertEqual(actual, point)
        XCTAssertTrue(dragged.0.swallow)
        XCTAssertEqual(dragged.0.actions, [.moved])
    }
}
