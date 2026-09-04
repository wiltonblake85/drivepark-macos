// SingleInstance.swift — exactly one icon.
//
// This file used to be much longer, and the complication left with the thing
// that caused it. While the LaunchAgent ran the app itself, registering the
// agent started a SECOND copy immediately, because KeepAlive launches the job
// the moment it loads while the copy the user already had keeps running. Two
// icons, two refresh timers, two Disk Arbitration approval callbacks, and two
// things that each believed they held the park veto. The code here then had to
// work out which of the two launchd was supervising, and on 2026-09-03 it got
// that wrong in a way that looked right: exactly one copy survived and it was
// the unsupervised one, which left the agent idle and the app unwatched.
//
// The agent runs the watchdog now (Sources/DriveParkWatchdog), and the watchdog
// starts the app through NSWorkspace, which activates a running copy rather
// than making a second one. There is no supervised copy to identify any more,
// so the rule is the plain one: whoever got here first keeps the field.
//
// A yielding copy exits ZERO on purpose. Standing down is not a failure, and
// the watchdog reads process presence rather than exit codes, so a second
// launch that yields must not look like the app dying.

import AppKit
import DriveParkKit

enum SingleInstance {
    /// - Returns: false when this copy should exit and leave the field to the
    ///   one that is already running.
    static func claim() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me.processIdentifier }

        Preferences.recordDiagnostic(
            "instances", others.isEmpty ? "1" : "\(others.count + 1), this one yielding")
        return others.isEmpty
    }
}
