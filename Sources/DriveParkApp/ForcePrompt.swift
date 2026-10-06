// ForcePrompt.swift: the one destructive thing in the app, gated by a human.
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
//   Never stale. The holders are read again just before this is shown, and
//   only the volumes it names are forced (audit H4).

import AppKit

enum ForcePrompt {
    /// - Parameter blockers: who holds files open right now, read fresh.
    /// - Parameter refusals: what macOS said when the park was refused, word
    ///   for word. When nothing shows up in lsof, as with a Time Machine
    ///   backup in progress, this is the only clue there is.
    /// - Returns: true only if a human read the warning and chose to proceed.
    static func confirm(volumes: [String], blockers: [String], refusals: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = volumes.count == 1
            ? "Force \(volumes[0]) to unmount?"
            : "Force \(volumes.count) volumes to unmount? \(volumes.joined(separator: ", "))"

        var body = "macOS refused the normal unmount."
        if !refusals.isEmpty {
            body += " It said: \(refusals.joined(separator: "; "))."
        }
        if blockers.isEmpty {
            body += "\n\nNo program shows files open there right now. Something "
            body += "macOS does not report, such as a backup in progress, may "
            body += "still be writing."
        } else {
            body += "\n\nHolding files open right now: \(blockers.joined(separator: ", "))."
        }
        body += "\n\nForcing tears the filesystem down anyway. Anything those "
        body += "programs had not finished writing is lost, and DrivePark "
        body += "cannot tell you what that was. Only the volumes named above "
        body += "are touched.\n\nQuitting the program named above and parking "
        body += "normally is the safe route."

        alert.informativeText = body
        alert.addButton(withTitle: "Quit that program myself")
        alert.addButton(withTitle: "Force unmount anyway")
        // Rightmost button is the destructive one and is not the default.
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
