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

import Foundation
import ServiceManagement

enum LoginItem {
    private static let agentPlist = "com.wiltonblake.drivepark.agent.plist"
    private static var service: SMAppService { .agent(plistName: agentPlist) }

    static var isEnabled: Bool { service.status == .enabled }

    /// Plain-language state, for the menu. The status enum matters more than
    /// the boolean: requiresApproval means the user switched DrivePark off in
    /// System Settings and only they can switch it back, which is not the same
    /// as "off".
    static var statusDescription: String {
        switch service.status {
        case .enabled:
            return "on"
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
        if nowEnabled != on {
            return "System reports keep-running is \(statusDescription)."
        }
        return nil
    }
}
