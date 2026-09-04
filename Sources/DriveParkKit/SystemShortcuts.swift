// SystemShortcuts.swift — what macOS has already claimed.
//
// RegisterEventHotKey happily accepts a combination the system already owns.
// Proven on 2026-09-01: registering Command Space, which is Spotlight, returns
// success. The app then reports REGISTERED and the shortcut never fires once,
// because the system consumes it first.
//
// So registration success is not proof a shortcut works, and this reads the
// user's actual reserved shortcuts rather than guessing from a hardcoded list
// that would drift with every macOS release and every person who rebinds
// something.

import Carbon.HIToolbox
import Foundation

public enum SystemShortcuts {
    struct Combination: Equatable {
        let keyCode: UInt32
        /// Cocoa modifier mask, matching what the preferences plist stores.
        let modifiers: UInt32
    }

    /// macOS keeps its own defaults in the system, not in the user's
    /// preferences file. Verified on 2026-09-01: com.apple.symbolichotkeys
    /// held four entries and no Spotlight, because nothing about Spotlight had
    /// been changed. Reading only that file therefore misses every shortcut
    /// the user has left alone, which is most of them.
    ///
    /// So this is the defaults table, overlaid below with whatever the user
    /// actually customised. It is curated rather than exhaustive: the aim is
    /// to catch the combinations someone might plausibly reach for, not to
    /// mirror every key in System Settings.
    /// Cocoa modifier masks, written out rather than taken from
    /// NSEvent.ModifierFlags. They are fixed bit positions that
    /// com.apple.symbolichotkeys stores directly, and spelling them here means
    /// this file needs no AppKit, so the CLI that links this library does not
    /// drag a UI framework in for four numbers.
    static let shift: UInt32 = 1 << 17
    static let ctrl: UInt32 = 1 << 18
    static let opt: UInt32 = 1 << 19
    static let cmd: UInt32 = 1 << 20

    private static var systemDefaults: [Int: (Combination, String)] {
        [
            64:  (Combination(keyCode: 49, modifiers: cmd), "Spotlight"),
            65:  (Combination(keyCode: 49, modifiers: opt | cmd), "Finder search"),
            60:  (Combination(keyCode: 49, modifiers: ctrl), "the previous input source"),
            61:  (Combination(keyCode: 49, modifiers: ctrl | opt), "the input source menu"),
            32:  (Combination(keyCode: 126, modifiers: ctrl), "Mission Control"),
            33:  (Combination(keyCode: 125, modifiers: ctrl), "Application windows"),
            79:  (Combination(keyCode: 123, modifiers: ctrl), "the space to the left"),
            81:  (Combination(keyCode: 124, modifiers: ctrl), "the space to the right"),
            28:  (Combination(keyCode: 20, modifiers: shift | cmd), "a screenshot to file"),
            29:  (Combination(keyCode: 20, modifiers: ctrl | shift | cmd), "a screenshot to the clipboard"),
            30:  (Combination(keyCode: 21, modifiers: shift | cmd), "a selection screenshot"),
            31:  (Combination(keyCode: 21, modifiers: ctrl | shift | cmd), "a selection screenshot to the clipboard"),
            184: (Combination(keyCode: 23, modifiers: shift | cmd), "the screenshot tools"),
            27:  (Combination(keyCode: 2, modifiers: opt | cmd), "hiding the Dock")
        ]
    }

    /// Not symbolic hot keys, but consumed before any app sees them all the
    /// same, or so destructive to steal globally that it amounts to the same.
    private static let alwaysReserved: [(Combination, String)] = [
        (Combination(keyCode: 48, modifiers: cmd), "the app switcher"),
        (Combination(keyCode: 48, modifiers: shift | cmd), "the app switcher"),
        (Combination(keyCode: 12, modifiers: cmd), "Quit in every app"),
        (Combination(keyCode: 13, modifiers: cmd), "Close Window in every app")
    ]

    /// The name of what already owns this combination, or nil when nothing
    /// known does. A nil is not a promise that the shortcut will fire, only
    /// that nothing in this table objects.
    public static func owner(keyCode: UInt32, carbonModifiers: UInt32) -> String? {
        owner(keyCode: keyCode, carbonModifiers: carbonModifiers,
              overrides: userOverrides())
    }

    /// The decision, separated from reading this Mac's live configuration.
    ///
    /// The split exists because the alert this feeds cannot be reached by
    /// pressing keys. Every combination it would fire on is claimed by macOS
    /// or by AppKit before the recorder's capture view sees it, and five were
    /// tried on 2026-09-04 without one arriving. So the table comes in as an
    /// argument, and the branch gets tested here rather than never.
    static func owner(keyCode: UInt32, carbonModifiers: UInt32,
                      overrides: [Int: Combination?]) -> String? {
        let wanted = Combination(keyCode: keyCode,
                                 modifiers: cocoaMask(from: carbonModifiers))

        for (combination, name) in alwaysReserved where combination == wanted {
            return name
        }

        for (identifier, entry) in systemDefaults {
            // A user override replaces the default entirely, and can disable it.
            if let override = overrides[identifier] {
                if let combination = override, combination == wanted { return entry.1 }
                continue
            }
            if entry.0 == wanted { return entry.1 }
        }

        // Anything the user bound that is not in the defaults table above.
        for (identifier, override) in overrides {
            guard systemDefaults[identifier] == nil,
                  let combination = override, combination == wanted else { continue }
            return "a macOS keyboard shortcut"
        }
        return nil
    }

    /// Identifier to combination, or to nil when the user disabled it.
    static func userOverrides() -> [Int: Combination?] {
        guard let store = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let table = store.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return [:] }

        return parseOverrides(table)
    }

    /// The parsing, split from the reading.
    ///
    /// Split on 2026-09-04 after a mutation test proved the first version of
    /// these tests could not fail. They handed `owner` a table that was
    /// already built, so breaking the enabled check in here changed nothing
    /// and the suite still went green. A test that cannot go red is
    /// decoration, and this is the half that reads a real plist.
    static func parseOverrides(_ table: [String: Any]) -> [Int: Combination?] {
        var result: [Int: Combination?] = [:]
        for (rawIdentifier, rawEntry) in table {
            guard let identifier = Int(rawIdentifier),
                  let entry = rawEntry as? [String: Any] else { continue }
            if entry["enabled"] as? Bool != true {
                result[identifier] = Combination?.none
                continue
            }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let code = parameters[1] as? Int,
                  let modifiers = parameters[2] as? Int
            else { continue }
            result[identifier] = Combination(
                keyCode: UInt32(truncatingIfNeeded: code),
                modifiers: UInt32(truncatingIfNeeded: modifiers) & maskOfInterest)
        }
        return result
    }

    private static let maskOfInterest: UInt32 = cmd | opt | ctrl | shift

    private static func cocoaMask(from carbon: UInt32) -> UInt32 {
        var mask: UInt32 = 0
        if carbon & UInt32(cmdKey) != 0 { mask |= cmd }
        if carbon & UInt32(optionKey) != 0 { mask |= opt }
        if carbon & UInt32(controlKey) != 0 { mask |= ctrl }
        if carbon & UInt32(shiftKey) != 0 { mask |= shift }
        return mask
    }
}
