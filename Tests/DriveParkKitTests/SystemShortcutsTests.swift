// SystemShortcutsTests — the guard's decision, tested where keystrokes cannot go.
//
// The alert this feeds refuses a shortcut macOS already owns. It cannot be
// reached by pressing keys, and that is not a gap in the test rig, it is the
// premise: every combination that would fire it is claimed before the recorder's
// capture view sees it. Five were tried by hand on 2026-09-04. Control Left,
// Control Space and Option Command D never arrived, because macOS consumed them.
// Command W closed the panel and Command Q would have quit the app, because
// AppKit handles both before keyDown. So the two entries in alwaysReserved that
// macOS does not consume are unreachable too, by a second mechanism.
//
// Hence these. They call the decision directly with a supplied override table,
// which also removes the dependence on how this particular Mac is configured.

import XCTest
@testable import DriveParkKit

final class SystemShortcutsTests: XCTestCase {
    // Carbon modifier bits, which is what RegisterEventHotKey and the recorder
    // both speak.
    private let cmdKeyBit: UInt32 = 0x0100
    private let shiftKeyBit: UInt32 = 0x0200
    private let optionKeyBit: UInt32 = 0x0800
    private let controlKeyBit: UInt32 = 0x1000

    private let space: UInt32 = 49
    private let letterP: UInt32 = 35
    private let tab: UInt32 = 48

    func testDriveParkDefaultIsNotClaimed() {
        // Control Option Command P, the shipped default. If this ever starts
        // reporting an owner, the default itself is the bug.
        XCTAssertNil(SystemShortcuts.owner(
            keyCode: letterP,
            carbonModifiers: controlKeyBit | optionKeyBit | cmdKeyBit,
            overrides: [:]))
    }

    func testSpotlightIsClaimedFromTheDefaultsTable() {
        XCTAssertEqual(SystemShortcuts.owner(
            keyCode: space, carbonModifiers: cmdKeyBit, overrides: [:]), "Spotlight")
    }

    func testAlwaysReservedBeatsAnEmptyTable() {
        // Command Tab is not a symbolic hot key, and is consumed all the same.
        XCTAssertEqual(SystemShortcuts.owner(
            keyCode: tab, carbonModifiers: cmdKeyBit, overrides: [:]), "the app switcher")
    }

    func testDisablingASystemShortcutFreesTheCombination() {
        // 64 is Spotlight. A user who switched it off in System Settings has
        // freed Command Space, and refusing it then would be wrong.
        XCTAssertNil(SystemShortcuts.owner(
            keyCode: space, carbonModifiers: cmdKeyBit,
            overrides: [64: SystemShortcuts.Combination?.none]))
    }

    func testRebindingMovesTheClaimRatherThanCopyingIt() {
        // Spotlight moved to Control Option Command P. The old combination is
        // free and the new one is spoken for, which is the whole point of
        // reading overrides instead of trusting a static table.
        let moved = SystemShortcuts.Combination(
            keyCode: letterP,
            modifiers: SystemShortcuts.ctrl | SystemShortcuts.opt | SystemShortcuts.cmd)
        let overrides: [Int: SystemShortcuts.Combination?] = [64: moved]

        XCTAssertNil(SystemShortcuts.owner(
            keyCode: space, carbonModifiers: cmdKeyBit, overrides: overrides))
        XCTAssertEqual(SystemShortcuts.owner(
            keyCode: letterP,
            carbonModifiers: controlKeyBit | optionKeyBit | cmdKeyBit,
            overrides: overrides), "Spotlight")
    }

    func testAnOverrideOutsideTheDefaultsTableIsStillRespected() {
        // Identifier 222 is not in the curated table. Something owns it anyway,
        // and the honest answer is that it is spoken for without naming it.
        let bound = SystemShortcuts.Combination(
            keyCode: letterP, modifiers: SystemShortcuts.ctrl | SystemShortcuts.cmd)
        XCTAssertEqual(SystemShortcuts.owner(
            keyCode: letterP, carbonModifiers: controlKeyBit | cmdKeyBit,
            overrides: [222: bound]), "a macOS keyboard shortcut")
    }

    func testShiftAloneDoesNotCollideWithAShiftlessClaim() {
        // Command Space is Spotlight. Shift Command Space is not, and the
        // comparison has to be exact rather than a subset match.
        XCTAssertNil(SystemShortcuts.owner(
            keyCode: space, carbonModifiers: cmdKeyBit | shiftKeyBit, overrides: [:]))
    }

    func testTheLiveReadIsAtLeastWellFormed() {
        // Not an assertion about this Mac's configuration, which no test should
        // depend on. Only that reading the real table does not trap or hang.
        _ = SystemShortcuts.userOverrides()
    }
}
