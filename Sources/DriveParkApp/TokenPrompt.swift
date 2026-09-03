// TokenPrompt.swift — one paste, once, and the notch channel is live.
//
// The Keychain read is tried first and needs no setup, but Transom's item is
// not readable from another process on this Mac (errSecItemNotFound, recorded
// in diagnostics), and a cross-app Keychain read that DOES resolve puts a
// modal system prompt in front of a park. So the supported path is the boring
// one: copy the token out of Transom, paste it in here, never think about it
// again.

import AppKit
import DriveParkKit

enum TokenPrompt {
    /// Sentinel returned when the user asks DrivePark to try the Keychain
    /// rather than pasting. Not a token, never stored.
    static let readFromKeychain = "\u{0}keychain"

    /// - Returns: the token the user pasted, or nil if they cancelled.
    ///   An empty field is a deliberate answer too: it clears the stored token.
    static func ask(current: String?) -> String?? {
        let alert = NSAlert()
        alert.messageText = "Transom API token"
        alert.informativeText = "Transom → Preferences → Advanced → Local API. "
            + "Copy the token and paste it here. It stays on this Mac, and it "
            + "only reaches Transom on 127.0.0.1.\n\nLeave it empty to clear."

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste the token"
        field.stringValue = current ?? ""
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Try the Keychain")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn { return .some(readFromKeychain) }
        guard choice == .alertFirstButtonReturn else { return nil }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(typed.isEmpty ? nil : typed)
    }
}
