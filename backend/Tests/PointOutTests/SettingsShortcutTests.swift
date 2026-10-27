import CoreGraphics
import XCTest
@testable import PointOut

final class SettingsShortcutTests: XCTestCase {
    func testSettingsOpensOnceAndOwnsRightReleaseAfterOptionIsReleased() {
        var right = SettingsShortcutStateMachine()
        let down = right.handle(.down(eligible: true))
        XCTAssertTrue(down.openSettings)
        XCTAssertTrue(down.swallow)
        let duplicate = right.handle(.down(eligible: true))
        XCTAssertFalse(duplicate.openSettings)
        XCTAssertTrue(duplicate.swallow)
        let afterModifierRelease = right.handle(.down(eligible: false))
        XCTAssertFalse(afterModifierRelease.openSettings)
        XCTAssertTrue(afterModifierRelease.swallow)
        XCTAssertTrue(right.handle(.dragged).swallow)
        // The release uses ownership, without consulting the current modifier state.
        XCTAssertTrue(right.handle(.up).swallow)
        XCTAssertFalse(right.handle(.up).swallow)
        XCTAssertFalse(right.ownsButton)
    }

    func testOrdinaryRightClickPassesAndTapInterruptionCannotConsumeLaterClick() {
        var right = SettingsShortcutStateMachine()
        XCTAssertFalse(right.handle(.down(eligible: false)).swallow)
        XCTAssertFalse(right.handle(.up).swallow)
        _ = right.handle(.down(eligible: true))
        _ = right.handle(.interrupted(buttonIsDown: true))
        XCTAssertTrue(right.ownsButton)
        XCTAssertTrue(right.handle(.up).swallow)
        _ = right.handle(.down(eligible: true))
        _ = right.handle(.interrupted(buttonIsDown: false))
        XCTAssertFalse(right.ownsButton)
        XCTAssertFalse(right.handle(.down(eligible: false)).swallow)
        XCTAssertFalse(right.handle(.up).swallow)
    }

    func testSettingsShortcutRequiresOnlyOptionAndIsIndependentOfWheelEnabled() {
        XCTAssertTrue(GlobalGestureMonitor.settingsShortcutEligible(.maskAlternate, stopping: false))
        for flags: CGEventFlags in [[], .maskControl, [.maskAlternate, .maskControl],
                                   [.maskAlternate, .maskShift], [.maskAlternate, .maskCommand]] {
            XCTAssertFalse(GlobalGestureMonitor.settingsShortcutEligible(flags, stopping: false))
        }
        XCTAssertFalse(GlobalGestureMonitor.settingsShortcutEligible(.maskAlternate, stopping: true))
        var wheel = GestureStateMachine()
        // A disabled wheel passes the left click, while right-click settings remains available.
        XCTAssertFalse(wheel.handle(.down(option: false)).swallow)
        var right = SettingsShortcutStateMachine()
        XCTAssertTrue(right.handle(.down(eligible: true)).openSettings)
    }

    func testOpeningSettingsOrDisablingWheelCancelsActionButKeepsPairedLeftUp() {
        var wheel = GestureStateMachine()
        XCTAssertEqual(wheel.handle(.down(option: true)).actions, [.began])
        XCTAssertEqual(wheel.handle(.optionReleased).actions, [.closed])
        XCTAssertTrue(wheel.ownsButton)
        XCTAssertTrue(wheel.handle(.dragged).actions.isEmpty)
        let release = wheel.handle(.up)
        XCTAssertTrue(release.swallow)
        XCTAssertTrue(release.actions.isEmpty)
        XCTAssertFalse(wheel.handle(.up).swallow)
        XCTAssertEqual(wheel.handle(.down(option: true)).actions, [.began])
    }

    func testRealRoutingKeepsSettingsAvailableWhenWheelIsDisabled() throws {
        let monitor = GlobalGestureMonitor(wheelTriggerEnabled: false)
        let record = ShortcutEvents()
        monitor.onEvent = { record.receive($0) }
        monitor.onSettingsRequested = { record.settings() }
        XCTAssertTrue(try route(monitor, .leftMouseDown, flags: .maskAlternate))
        XCTAssertTrue(try route(monitor, .leftMouseUp, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .rightMouseDown, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .rightMouseDown, flags: []))
        XCTAssertFalse(try route(monitor, .rightMouseUp, flags: []))
        XCTAssertEqual(record.values, ["settings"])
        XCTAssertTrue(try route(monitor, .rightMouseDown, flags: []))
        XCTAssertTrue(try route(monitor, .rightMouseUp, flags: []))
    }

    func testRealRoutingRapidDisableEnableCancelsOldGestureWithoutCancellingNewOne() throws {
        let monitor = GlobalGestureMonitor()
        let record = ShortcutEvents()
        monitor.onEvent = { record.receive($0) }
        XCTAssertFalse(try route(monitor, .leftMouseDown, flags: .maskAlternate))
        monitor.setWheelTriggerEnabled(false)
        monitor.setWheelTriggerEnabled(true)
        XCTAssertFalse(try route(monitor, .leftMouseUp, flags: .maskAlternate))
        XCTAssertEqual(record.values, ["began", "closed"])
        XCTAssertFalse(try route(monitor, .leftMouseDown, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .leftMouseUp, flags: .maskAlternate))
        XCTAssertEqual(record.values, ["began", "closed", "began", "released"])
    }

    func testRealRoutingSettingsCancelsHeldWheelWithoutReleasingAction() throws {
        let monitor = GlobalGestureMonitor()
        let record = ShortcutEvents()
        monitor.onEvent = { record.receive($0) }
        monitor.onSettingsRequested = { record.settings() }
        XCTAssertFalse(try route(monitor, .leftMouseDown, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .rightMouseDown, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .leftMouseUp, flags: .maskAlternate))
        XCTAssertFalse(try route(monitor, .rightMouseUp, flags: []))
        XCTAssertEqual(record.values, ["began", "closed", "settings"])
    }

    private func route(_ monitor: GlobalGestureMonitor, _ type: CGEventType,
                       flags: CGEventFlags) throws -> Bool {
        let right = [.rightMouseDown, .rightMouseUp].contains(type)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                         mouseCursorPosition: .zero, mouseButton: right ? .right : .left))
        event.flags = flags
        // Direct routing only: no global event posting, tap, screen capture or user UI.
        return monitor.receive(type, event) != nil
    }
}

private final class ShortcutEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func settings() { lock.withLock { events.append("settings") } }
    func receive(_ event: GestureEvent) {
        let name: String
        switch event {
        case .began: name = "began"
        case .moved: name = "moved"
        case .released: name = "released"
        case .closed: name = "closed"
        case .clearAllMarkers: name = "clear"
        case .permissionLost: name = "permission"
        }
        lock.withLock { events.append(name) }
    }
}
