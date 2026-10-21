import XCTest
@testable import StratagemCore

final class HoldShortcutTests: XCTestCase {
    func testOnlyLeftShiftTabBegins() {
        var state = HoldShortcutState()
        XCTAssertEqual(state.handle(.down(48, repeatKey: false), leftShift: false), .init(consume: false, effects: []))
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.handle(.down(48, repeatKey: false), leftShift: true), .init(consume: true, effects: [.began]))
        XCTAssertTrue(state.active)
    }
    func testTabAndArrowsPassThroughWithoutChord() {
        var state = HoldShortcutState()
        for code: UInt16 in [48, 126, 125, 123, 124, 36, 53] {
            XCTAssertEqual(state.handle(.down(code, repeatKey: false), leftShift: false), .init(consume: false, effects: []))
            XCTAssertFalse(state.handle(.up(code), leftShift: false).consume)
        }
    }
    func testHoldingShiftAloneDoesNotCaptureDirections() {
        var state = HoldShortcutState()
        XCTAssertEqual(state.handle(.down(126, repeatKey: false), leftShift: true), .init(consume: false, effects: []))
    }
    func testRightShiftTabIsUnchanged() {
        var state = HoldShortcutState()
        // The input adapter supplies the device-specific LEFT bit, not the aggregate Shift bit.
        XCTAssertFalse(state.handle(.down(48, repeatKey: false), leftShift: false).consume)
        XCTAssertFalse(state.handle(.up(48), leftShift: false).consume)
    }
    func testReleaseTabFirstEndsAndNextGestureWorks() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.up(48), leftShift: true), .init(consume: true, effects: [.ended]))
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.handle(.down(48, repeatKey: false), leftShift: true).effects, [.began])
    }
    func testReleaseLeftShiftFirstEndsEvenIfRightShiftRemains() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.modifiersChanged, leftShift: false), .init(consume: false, effects: [.ended]))
        XCTAssertEqual(state.handle(.up(48), leftShift: false), .init(consume: true, effects: []))
    }
    func testHeldArrowDirectionsAndPairedKeyUps() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        for (code, direction) in [(UInt16(126), Direction.up), (125, .down), (123, .left), (124, .right)] {
            XCTAssertEqual(state.handle(.down(code, repeatKey: false), leftShift: true), .init(consume: true, effects: [.direction(direction)]))
            XCTAssertTrue(state.handle(.up(code), leftShift: true).consume)
        }
    }
    func testRepeatNeverDuplicatesInputOrReopensAfterEscape() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.down(48, repeatKey: true), leftShift: true), .init(consume: true, effects: []))
        _ = state.handle(.down(126, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.down(126, repeatKey: true), leftShift: true), .init(consume: true, effects: []))
        XCTAssertEqual(state.handle(.down(53, repeatKey: false), leftShift: true).effects, [.cancel])
        XCTAssertEqual(state.handle(.down(48, repeatKey: true), leftShift: true).effects, [])
        XCTAssertFalse(state.active)
    }
    func testRepeatFromOwnedArrowDoesNotLeakAfterRelease() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        _ = state.handle(.down(126, repeatKey: false), leftShift: true)
        _ = state.handle(.up(48), leftShift: true)
        XCTAssertTrue(state.handle(.down(126, repeatKey: true), leftShift: true).consume)
        XCTAssertTrue(state.handle(.up(126), leftShift: true).consume)
        XCTAssertFalse(state.handle(.down(126, repeatKey: false), leftShift: true).consume)
    }
    func testExtraModifiersEndCaptureAndDoNotStartIt() {
        var state = HoldShortcutState()
        XCTAssertFalse(state.handle(.down(48, repeatKey: false), leftShift: true, otherModifiers: true).consume)
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.modifiersChanged, leftShift: true, otherModifiers: true).effects, [.ended])
    }
    func testConfirmationRequiresHeldChord() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        XCTAssertEqual(state.handle(.down(36, repeatKey: false), leftShift: true).effects, [.confirm])
        _ = state.handle(.up(36), leftShift: true)
        _ = state.handle(.up(48), leftShift: true)
        XCTAssertFalse(state.handle(.down(36, repeatKey: false), leftShift: true).consume)
    }
    func testResetRecoversFromLostFocusOrCapture() {
        var state = HoldShortcutState()
        _ = state.handle(.down(48, repeatKey: false), leftShift: true)
        state.reset()
        XCTAssertEqual(state.handle(.down(48, repeatKey: false), leftShift: true).effects, [.began])
    }
    func testNewDefaultAndOldConfigurationBothValidate() throws {
        var config = Configuration()
        XCTAssertEqual(config.settings.hotkeyCode, 1)
        XCTAssertEqual(config.settings.hotkeyModifiers, 2304)
        XCTAssertEqual(config.settings.panelPosition, "topLeft")
        try ConfigurationStore.validate(config)
        config.settings.hotkeyCode = 1; config.settings.hotkeyModifiers = 6144; config.settings.panelPosition = "center"
        try ConfigurationStore.validate(config)
        config.settings.hotkeyCode = 48; config.settings.hotkeyModifiers = 512
        try ConfigurationStore.validate(config)
    }
    func testShortcutModifiersAllowCommandAndRejectCapsLock() throws {
        var config = Configuration()
        for modifiers: UInt32 in [256, 512, 2048, 4096, 6400, 6912] {
            config.settings.hotkeyModifiers = modifiers
            XCTAssertNoThrow(try ConfigurationStore.validate(config))
        }
        for modifiers: UInt32 in [0, 1024, 8192] {
            config.settings.hotkeyModifiers = modifiers
            XCTAssertThrowsError(try ConfigurationStore.validate(config))
        }
    }
}
