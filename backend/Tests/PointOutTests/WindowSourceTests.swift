import XCTest
@testable import PointOut

final class WindowSourceTests: XCTestCase {
    let bounds = CGRect(x: -500, y: -100, width: 500, height: 400)
    var point: CGPoint { CGPoint(x: -200, y: 40) }

    func testPlatformHitSelectsSourceDespiteForeignTransparentRectangles() {
        let actual = CaptureWindowIdentity(id: 10, processID: 7, frame: bounds)
        let result = WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in 10 }, metadata: { $0 == 10 ? actual : nil })
        XCTAssertEqual(result, actual)
    }
    func testOurOverlayWindowsAreSkippedUsingTheSamePoint() {
        let own = CaptureWindowIdentity(id: 11, processID: 99, frame: bounds)
        let source = CaptureWindowIdentity(id: 10, processID: 7, frame: bounds)
        var excluded: [Int] = []
        let result = WindowHitResolver.resolve(point: point, ownPID: 99, hit: { below in
            excluded.append(below); return below == 0 ? 11 : 10
        }, metadata: { $0 == 11 ? own : source })
        XCTAssertEqual(excluded, [0, 11]); XCTAssertEqual(result, source)
    }
    func testFloatingWindowFromAnotherAppIsTheTargetRatherThanItsBackground() {
        let floating = CaptureWindowIdentity(id: 44, processID: 8, frame: bounds)
        let result = WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in 44 }, metadata: { _ in floating })
        XCTAssertEqual(result?.id, 44); XCTAssertEqual(result?.processID, 8)
    }
    func testClosedOrMovedWindowAndInvalidCoordinatesCannotResolveSource() {
        XCTAssertNil(WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in 10 }, metadata: { _ in nil }))
        let moved = CaptureWindowIdentity(id: 10, processID: 7, frame: bounds.offsetBy(dx: 1000, dy: 0))
        XCTAssertNil(WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in 10 }, metadata: { _ in moved }))
        var calls = 0
        XCTAssertNil(WindowHitResolver.resolve(point: CGPoint(x: CGFloat.nan, y: 0), ownPID: 99, hit: { _ in calls += 1; return 0 }, metadata: { _ in nil }))
        XCTAssertEqual(calls, 0)
    }
    func testUnavailableHitAndOwnWindowCycleTerminate() {
        XCTAssertNil(WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in 0 }, metadata: { _ in nil }))
        var calls = 0
        let own = CaptureWindowIdentity(id: 11, processID: 99, frame: bounds)
        XCTAssertNil(WindowHitResolver.resolve(point: point, ownPID: 99, hit: { _ in calls += 1; return 11 }, metadata: { _ in own }))
        XCTAssertEqual(calls, 2)
    }
}
