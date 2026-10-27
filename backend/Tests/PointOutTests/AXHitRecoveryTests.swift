import XCTest
@testable import PointOut

final class AXHitRecoveryTests: XCTestCase {
    func testTransientAXFailureRecoversExactlyOnce() {
        var calls = 0
        let result: AXHitOutcome<String> = AXHitRecovery.resolve(allowAttempt: { true }) {
            calls += 1
            return calls == 1 ? .transientFailure : .found("original point")
        }
        if case .found(let target) = result { XCTAssertEqual(target, "original point") }
        else { XCTFail("Recoverable AX message did not recover") }
        XCTAssertEqual(calls, 2)
    }
    func testUnsupportedOrPermissionFailureDoesNotRetry() {
        var calls = 0
        let _: AXHitOutcome<String> = AXHitRecovery.resolve(allowAttempt: { true }) {
            calls += 1
            return .unavailable
        }
        XCTAssertEqual(calls, 1)
    }
    func testPersistentTransientFailureCannotCreateRetryStorm() {
        var calls = 0
        let result: AXHitOutcome<String> = AXHitRecovery.resolve(allowAttempt: { true }) {
            calls += 1
            return .transientFailure
        }
        if case .transientFailure = result {} else { XCTFail("Failure must be preserved") }
        XCTAssertEqual(calls, 2)
    }
    func testExhaustedBudgetPreventsSecondAttempt() {
        var allowed = 1
        var calls = 0
        let result: AXHitOutcome<String> = AXHitRecovery.resolve(allowAttempt: {
            defer { allowed -= 1 }
            return allowed > 0
        }) {
            calls += 1
            return .transientFailure
        }
        if case .transientFailure = result {} else { XCTFail("Failure must be preserved") }
        XCTAssertEqual(calls, 1)
        let _: AXHitOutcome<String> = AXHitRecovery.resolve(allowAttempt: { false }) {
            calls += 1; return .found("must not query")
        }
        XCTAssertEqual(calls, 1)
    }
}
