// LoginItem.swift — start at login, and come back if something kills it.
//
// One toggle, two behaviours, because they are the same promise: DrivePark is
// running. It used to be SMAppService.mainApp, which only covers login. That
// left the case that actually happened on 2026-09-01: the app was replaced
// underneath itself, macOS terminated it silently with no crash report, and
// the only evidence was a gap in the menu bar. Launch at login would not have
// helped, because nobody logged out.
//
// So this registers a LaunchAgent instead, with RunAtLoad for the login half
// and KeepAlive{SuccessfulExit: false} for the watchdog half.
//
// The SuccessfulExit condition matters more than it looks. Plain KeepAlive
// would relaunch the app the instant you chose Quit, which is what malware
// does. Quit from the menu exits cleanly, so DrivePark stays quit. A kill, a
// crash, or a bundle swapped out from under it is an abnormal exit, and only
// those come back.

import CryptoKit
import DriveParkKit
import Foundation
import ServiceManagement

enum LoginItem {
    private static let agentPlist = "com.wiltonblake.drivepark.agent.plist"
    private static var service: SMAppService { .agent(plistName: agentPlist) }

    static var isEnabled: Bool { service.status == .enabled }

    /// SHA-256 of the agent plist that currently sits in the bundle.
    ///
    /// launchd keeps the job definition it was handed at registration time.
    /// Editing the plist inside the bundle changes nothing on its own, and a
    /// kickstart runs the stale definition rather than the new one. Watched
    /// happen on 2026-09-03: the plist on disk said DriveParkWatchdog,
    /// backgroundtaskmanagementd had already read DriveParkWatchdog, and
    /// launchd still reported
    ///     program identifier = Contents/MacOS/DrivePark
    /// so the kickstart restarted the app and the watchdog never ran.
    private static var plistFingerprint: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(agentPlist)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Called once at launch. Re-registers when the bundled plist no longer
    /// matches what launchd was given, which is every app update that changes
    /// the agent, and does nothing at all in the ordinary case.
    static func reconcile() {
        guard let fingerprint = plistFingerprint else {
            Preferences.recordDiagnostic("agentPlist", "missing from the bundle")
            return
        }

        // Finish a migration that was interrupted last time. On the version
        // this replaces, the app WAS the job, so the unregister below killed
        // this process before the register could run.
        if Preferences.agentReRegisterPending, service.status != .enabled {
            try? service.register()
            Preferences.registeredAgentFingerprint =
                service.status == .enabled ? fingerprint : nil
            Preferences.agentReRegisterPending = false
            Preferences.recordDiagnostic("agentPlist", "re-registered after an interrupted update")
            return
        }

        guard service.status == .enabled,
              Preferences.registeredAgentFingerprint != fingerprint else { return }

        Preferences.agentReRegisterPending = true
        try? service.unregister()
        try? service.register()
        let settled = service.status == .enabled
        Preferences.registeredAgentFingerprint = settled ? fingerprint : nil
        Preferences.agentReRegisterPending = false
        Preferences.recordDiagnostic(
            "agentPlist", settled ? "re-registered on a changed plist" : "re-registration failed")
    }


    /// Plain-language state, for the menu. The status enum matters more than
    /// the boolean: requiresApproval means the user switched DrivePark off in
    /// System Settings and only they can switch it back, which is not the same
    /// as "off".
    static var statusDescription: String {
        switch service.status {
        case .enabled:
            // Registered is not the same as watched. The agent can be
            // enabled while the watchdog process is dead, and a menu that
            // reads "on" over a watchdog that is not running is the exact
            // false assurance this app exists to refuse.
            return Preferences.watchdogLooksAlive
                ? "on"
                : "on, but the watchdog is not answering"
        case .notRegistered:
            return "off"
        case .requiresApproval:
            return "blocked in System Settings, Login Items"
        case .notFound:
            return "unavailable, the watchdog is missing from the app bundle"
        @unknown default:
            return "unknown"
        }
    }

    /// - Returns: nil on success, or the failure in words. Never swallow this:
    ///   silently failing to register is the exact kind of quiet lie DrivePark
    ///   exists to avoid.
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            return error.localizedDescription
        }
        // Verify against a fresh status read rather than trusting the call.
        let nowEnabled = service.status == .enabled
        // Remember WHICH plist launchd was handed, so a later app update that
        // changes it can tell that a re-registration is owed.
        Preferences.registeredAgentFingerprint = nowEnabled ? plistFingerprint : nil
        if nowEnabled != on {
            return "System reports keep-running is \(statusDescription)."
        }
        return nil
    }
}
