// LoginItem.swift — launch at login via SMAppService.
//
// The status enum matters more than the boolean. `requiresApproval` means the
// user disabled DrivePark in System Settings and only they can turn it back
// on; reporting that as plain "off" would send them clicking a switch that
// silently does nothing.

import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Plain-language state, for the menu.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "on"
        case .notRegistered:
            return "off"
        case .requiresApproval:
            return "blocked in System Settings, Login Items"
        case .notFound:
            return "unavailable, the app is not in a launchable location"
        @unknown default:
            return "unknown"
        }
    }

    /// - Returns: nil on success, or the failure in words. Never swallow this:
    ///   a login item that silently failed to register is the exact kind of
    ///   quiet lie DrivePark exists to avoid.
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return error.localizedDescription
        }
        // Verify against a fresh status read rather than trusting the call.
        let nowEnabled = SMAppService.mainApp.status == .enabled
        if nowEnabled != on {
            return "System reports launch at login is \(statusDescription)."
        }
        return nil
    }
}
