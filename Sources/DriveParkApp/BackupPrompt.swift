// BackupPrompt.swift: one question before a park stops a backup.
//
// Asked only for a park a person started, after the engine has refused it
// because Time Machine is writing to one of the drives. Automatic parks never
// ask and never stop a backup: a screen lock is not someone deciding that
// tonight's backup can wait.

import AppKit

enum BackupPrompt {
    /// - Returns: true only if a person chose to stop the backup and park.
    static func confirm(volumes: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let names = volumes.joined(separator: ", ")
        alert.messageText = "Time Machine is backing up to \(names)"
        alert.informativeText = "Parking now unmounts \(names) and stops the backup. "
            + "Time Machine starts again on its next backup, or when you choose Back Up Now."
            + "\n\nWaiting for the backup to finish and parking then loses nothing."
        alert.addButton(withTitle: "Wait for the backup")
        alert.addButton(withTitle: "Stop the backup and park")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
