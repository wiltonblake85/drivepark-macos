// ForcePrompt.swift — the one destructive thing in the app, gated by a human.
//
// Force unmount tears a filesystem down with files still open. Whatever those
// files had not written yet is gone. That is a real cost, so the design rules
// are:
//
//   Never a stored preference. A "force" switch left on months ago, firing on
//   a screen lock while something writes, is the worst bug this app could ship.
//   Never reachable from a trigger. Automatic parking is polite by definition.
//   Never offered until a normal park has failed and named the blocker, so the
//   user is choosing between two known things rather than ticking a box.
//   Never one click. The alert says what will be lost and who is holding it.

import AppKit

enum ForcePrompt {
    /// - Returns: true only if a human read the warning and chose to proceed.
    static func confirm(volumes: [String], blockers: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = volumes.count == 1
            ? "Force \(volumes[0]) to unmount?"
            : "Force \(volumes.count) volumes to unmount?"

        var body = "macOS refused the normal unmount because files are still open."
        if !blockers.isEmpty {
            body += "\n\nHolding them open: \(blockers.joined(separator: ", "))."
        }
        body += "\n\nForcing tears the filesystem down anyway. Anything those "
        body += "programs had not finished writing is lost, and DrivePark "
        body += "cannot tell you what that was.\n\nQuitting the program named "
        body += "above and parking normally is the safe route."

        alert.informativeText = body
        alert.addButton(withTitle: "Quit that program myself")
        alert.addButton(withTitle: "Force unmount anyway")
        // Rightmost button is the destructive one and is not the default.
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
