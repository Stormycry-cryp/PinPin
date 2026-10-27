import XCTest
@testable import PointOut

final class CaptureRulesTests: XCTestCase {
    func testCancelRetainsMouseOwnershipUntilMatchingUp() {
        var state = GestureStateMachine()
        XCTAssertEqual(state.handle(.down(option: true)).actions, [.began])
        XCTAssertTrue(state.ownsButton)
        XCTAssertEqual(state.handle(.optionReleased).actions, [.closed])
        XCTAssertTrue(state.handle(.dragged).swallow)
        let up = state.handle(.up)
        XCTAssertTrue(up.swallow)
        XCTAssertTrue(up.actions.isEmpty)
        XCTAssertFalse(state.handle(.up).swallow)
        XCTAssertFalse(state.handle(.down(option: false)).swallow)
    }

    func testReleaseDoesNotCloseWheelOrExecuteWithoutUIHitTest() {
        var state = GestureStateMachine()
        _ = state.handle(.down(option: true))
        XCTAssertEqual(state.handle(.dragged).actions, [.moved])
        XCTAssertEqual(state.handle(.up).actions, [.released])
        XCTAssertTrue(state.wheelOpen)
        XCTAssertFalse(state.ownsButton)
        // Another press can select in the same wheel; its original anchor remains unchanged.
        XCTAssertEqual(state.handle(.down(option: true)).actions, [.moved])
        XCTAssertEqual(state.handle(.up).actions, [.released])
        XCTAssertEqual(state.handle(.optionReleased).actions, [.closed])
        XCTAssertTrue(state.handle(.optionReleased).actions.isEmpty)
    }

    func testOrdinaryMouseAndDuplicateDownNeverCreateGesture() {
        var state = GestureStateMachine()
        XCTAssertFalse(state.handle(.down(option: false)).swallow)
        XCTAssertFalse(state.handle(.dragged).swallow)
        XCTAssertFalse(state.handle(.up).swallow)
        _ = state.handle(.down(option: true))
        XCTAssertTrue(state.handle(.down(option: true)).actions.isEmpty)
        XCTAssertEqual(state.handle(.escape).actions, [.closed])
        XCTAssertTrue(state.handle(.up).swallow)
        XCTAssertFalse(state.wheelOpen)
    }

    func testTapInterruptionWithUpAlreadyPassedDoesNotSwallowNextClick() {
        var state = GestureStateMachine()
        _ = state.handle(.down(option: true))
        XCTAssertEqual(state.handle(.interrupted(buttonIsDown: false)).actions, [.closed])
        XCTAssertFalse(state.ownsButton)
        XCTAssertFalse(state.handle(.up).swallow)
        XCTAssertFalse(state.handle(.down(option: false)).swallow)
        _ = state.handle(.down(option: true))
        _ = state.handle(.interrupted(buttonIsDown: true))
        XCTAssertTrue(state.handle(.up).swallow)
    }

    func testFreshOrdinaryDownClearsOwnershipIfOriginalUpWasMissed() {
        var state = GestureStateMachine()
        _ = state.handle(.down(option: true))
        _ = state.handle(.interrupted(buttonIsDown: true))
        XCTAssertFalse(state.handle(.down(option: false)).swallow)
        XCTAssertFalse(state.ownsButton)
        XCTAssertFalse(state.handle(.up).swallow)
    }

    func testSelectionMustBelongToSourceAndContainOriginalClick() {
        let range = NSRange(location: 10, length: 8)
        let bounds = CGRect(x: -1000, y: -300, width: 100, height: 20)
        let point = CGPoint(x: -970, y: -290)
        XCTAssertTrue(CaptureRules.validSelection(range: range, bounds: bounds, point: point, hitProcess: 5, anchorProcess: 5))
        XCTAssertFalse(CaptureRules.validSelection(range: range, bounds: bounds, point: .zero, hitProcess: 5, anchorProcess: 5))
        XCTAssertFalse(CaptureRules.validSelection(range: range, bounds: bounds, point: point, hitProcess: 6, anchorProcess: 5))
        XCTAssertFalse(CaptureRules.validSelection(range: range, bounds: nil, point: point, hitProcess: 5, anchorProcess: 5))
        XCTAssertFalse(CaptureRules.validSelection(range: NSRange(location: 0, length: 0), bounds: bounds, point: point, hitProcess: 5, anchorProcess: 5))
    }

    func testCoordinateConversionPreservesNegativeAndUpperDisplayPositions() {
        XCTAssertEqual(CaptureRules.presentationPoint(CGPoint(x: 200, y: 100), primaryHeight: 900), CGPoint(x: 200, y: 800))
        XCTAssertEqual(CaptureRules.presentationPoint(CGPoint(x: -800, y: 100), primaryHeight: 900), CGPoint(x: -800, y: 800))
        XCTAssertEqual(CaptureRules.presentationPoint(CGPoint(x: 400, y: -300), primaryHeight: 900), CGPoint(x: 400, y: 1200))
        XCTAssertEqual(CaptureRules.presentationPoint(CGPoint(x: 10, y: 1200), primaryHeight: 900), CGPoint(x: 10, y: -300))
    }

    func testPointCropIsBoundedToClickedDisplayAndNormalizesTopLeft() {
        let display = CGRect(x: -1600, y: -400, width: 1600, height: 1000)
        let point = CGPoint(x: -1590, y: -390)
        let crop = CaptureRules.crop(around: point, in: display)!
        XCTAssertEqual(crop.origin, display.origin)
        XCTAssertTrue(display.contains(crop))
        let normalized = CaptureRules.normalizedPoint(point, in: crop)!
        XCTAssertEqual(normalized.x, 10 / 960, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 10 / 640, accuracy: 0.0001)
        XCTAssertNil(CaptureRules.crop(around: CGPoint(x: 10, y: 20), in: display))
    }

    func testInvalidGeometryIsRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(CaptureRules.crop(around: .zero, in: bounds, size: CGSize(width: -1, height: 10)))
        XCTAssertNil(CaptureRules.crop(around: CGPoint(x: CGFloat.nan, y: 0), in: bounds))
        XCTAssertNil(CaptureRules.normalizedPoint(.zero, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 2)))
    }
}
