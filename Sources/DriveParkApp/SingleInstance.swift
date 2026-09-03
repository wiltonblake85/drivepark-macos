// SingleInstance.swift — exactly one icon, and the right one.
//
// Registering the watchdog agent starts a second copy immediately, because
// KeepAlive launches the job the moment it loads while the copy the user
// already had keeps running. Two icons, two refresh timers, two Disk
// Arbitration approval callbacks, and two things that each believe they hold
// the park veto. Seen on 2026-09-03 seconds after the toggle was first used.
//
// The first fix used "newest wins" and was wrong in a way that looked right:
// exactly one copy survived, and it was the UNSUPERVISED one, which left the
// agent idle and the app unwatched. A watchdog that terminates the process it
// is watching is worse than no watchdog.
//
// So the rule is: the supervised copy always wins, whatever its age. launchd
// sets XPC_SERVICE_NAME to the job label for jobs it manages, verified on this
// hardware: the agent-started copy carries
// XPC_SERVICE_NAME=com.wiltonblake.drivepark.agent and a hand-started one
// carries nothing.
//
// A yielding copy exits ZERO on purpose. KeepAlive is SuccessfulExit:false, so
// a clean exit is not a restart trigger. Exiting non-zero would have launchd
// relaunch it and the copies would fight forever.

import AppKit
import DriveParkKit

enum SingleInstance {
    static let agentLabel = "com.wiltonblake.drivepark.agent"

    /// True when launchd started this process from the watchdog agent.
    static var isSupervised: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }

    /// - Returns: false when this copy should exit and leave the field to
    ///   another instance.
    static func claim() -> Bool {
        Preferences.recordDiagnostic("supervised", isSupervised ? "yes" : "no")

        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return true }

        if isSupervised {
            // The watched copy takes the field.
            for other in others { other.terminate() }
            return true
        }
        // Someone is already here and, if the agent is on, they are the copy
        // launchd is keeping alive. Yield rather than orphan the watchdog.
        return false
    }
}
