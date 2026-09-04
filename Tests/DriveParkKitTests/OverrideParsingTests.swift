// OverrideParsingTests — the half that reads a real plist.
//
// These exist because a mutation test caught the first suite lying. Breaking the
// enabled check in parseOverrides changed nothing and eight tests still passed,
// because every one of them handed `owner` a table that was already built. The
// parser is where "the user switched this off in System Settings" is decided,
// and it had no coverage at all.
//
// The shapes below are what com.apple.symbolichotkeys actually stores: an
// enabled flag, and a value dictionary whose parameters are [character, key
// code, modifier mask].

import XCTest
@testable import DriveParkKit

final class OverrideParsingTests: XCTestCase {
    private func entry(enabled: Bool, keyCode: Int, modifiers: Int) -> [String: Any] {
        ["enabled": enabled,
         "value": ["type": "standard",
                   "parameters": [65535, keyCode, modifiers]]]
    }

    func testAnEnabledEntryParsesToItsCombination() {
        let parsed = SystemShortcuts.parseOverrides([
            "64": entry(enabled: true, keyCode: 49,
                        modifiers: Int(SystemShortcuts.cmd))
        ])
        XCTAssertEqual(parsed.count, 1)
        let combination = try? XCTUnwrap(parsed[64])
        XCTAssertEqual(combination ?? nil,
                       SystemShortcuts.Combination(keyCode: 49,
                                                   modifiers: SystemShortcuts.cmd))
    }

    /// The one the mutation test proved was untested. A disabled entry has to
    /// become a present-but-nil override, because that is what frees the
    /// combination for DrivePark to take.
    func testADisabledEntryParsesToAPresentNil() {
        let parsed = SystemShortcuts.parseOverrides([
            "64": entry(enabled: false, keyCode: 49,
                        modifiers: Int(SystemShortcuts.cmd))
        ])
        XCTAssertTrue(parsed.keys.contains(64), "the identifier must still be present")
        XCTAssertEqual(parsed[64] ?? nil, nil, "and it must carry no combination")
    }

    /// End to end through both halves: a disabled Spotlight frees Command Space.
    func testDisabledSpotlightFreesCommandSpaceThroughBothHalves() {
        let table: [String: Any] = [
            "64": entry(enabled: false, keyCode: 49, modifiers: Int(SystemShortcuts.cmd))
        ]
        XCTAssertNil(SystemShortcuts.owner(keyCode: 49, carbonModifiers: 0x0100,
                                           overrides: SystemShortcuts.parseOverrides(table)))
    }

    func testAnEnabledRebindIsHonouredThroughBothHalves() {
        let table: [String: Any] = [
            "64": entry(enabled: true, keyCode: 35,
                        modifiers: Int(SystemShortcuts.ctrl | SystemShortcuts.opt | SystemShortcuts.cmd))
        ]
        let overrides = SystemShortcuts.parseOverrides(table)
        XCTAssertNil(SystemShortcuts.owner(keyCode: 49, carbonModifiers: 0x0100,
                                           overrides: overrides))
        XCTAssertEqual(SystemShortcuts.owner(keyCode: 35, carbonModifiers: 0x1000 | 0x0800 | 0x0100,
                                             overrides: overrides), "Spotlight")
    }

    func testModifierBitsOutsideTheOnesWeCareAboutAreDropped() {
        // Caps Lock is 1 << 16 and appears in real entries. Keeping it would
        // make an otherwise identical combination fail to match.
        let capsLock = 1 << 16
        let parsed = SystemShortcuts.parseOverrides([
            "64": entry(enabled: true, keyCode: 49,
                        modifiers: Int(SystemShortcuts.cmd) | capsLock)
        ])
        XCTAssertEqual(parsed[64] ?? nil,
                       SystemShortcuts.Combination(keyCode: 49,
                                                   modifiers: SystemShortcuts.cmd))
    }

    func testMalformedEntriesAreSkippedRatherThanCrashing() {
        let parsed = SystemShortcuts.parseOverrides([
            "not a number": entry(enabled: true, keyCode: 49, modifiers: 0),
            "70": ["enabled": true],                                   // no value
            "71": ["enabled": true, "value": ["parameters": [1, 2]]],  // short
            "72": "not a dictionary"
        ])
        XCTAssertTrue(parsed.isEmpty)
    }
}
