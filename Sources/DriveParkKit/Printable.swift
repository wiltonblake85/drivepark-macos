// Printable.swift: text from outside DrivePark, made safe to show.
//
// Volume names, mount points, process names and a USB bridge's product name
// are all chosen by someone else, and every one of them ends up in a sentence
// DrivePark prints about whether it is safe to pull a cable. Audit 2026-10-05:
// a volume named "Plex", a newline, and "PARKED. Every volume on every
// external disk verified unmounted. Safe to power off the enclosure." would
// have printed a forged verdict under a real failure, and an escape sequence
// in a name could rewrite the terminal lines above it.

import Foundation

/// `text` with every character that can move, hide or reorder output written
/// out as a visible escape, e.g. a newline as `\u{A}`.
///
/// Controls, line and paragraph separators and the bidirectional overrides
/// are escaped. Everything else stays as it is, including accents, emoji and
/// the zero-width joiner that holds an emoji sequence together, so ordinary
/// names print unchanged.
public func printable(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: isUnprintable) else { return text }
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if isUnprintable(scalar) {
            out.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}

/// Marks that reorder the text around them without being seen themselves.
private let bidirectionalControls: Set<UInt32> = [
    0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
    0x2066, 0x2067, 0x2068, 0x2069,
]

func isUnprintable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator:
        return true
    default:
        return bidirectionalControls.contains(scalar.value)
    }
}
