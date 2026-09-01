// Notifier.swift — the part that tells you without you having to look.
//
// The whole reason this exists: the tower auto-parked one morning, Plex Media
// Server kept running against a library that was no longer there, and nothing
// on screen said a word. The app knew. It just never mentioned it.
//
// Authorization is reported honestly. A notifier that silently posts nothing
// because permission was declined is worse than no notifier, because you stop
// checking the menu.

import Foundation
import AppKit
import UserNotifications
import DriveParkKit

@MainActor
final class Notifier {
    static let shared = Notifier()

    private var asked = false
    private(set) var authorized = false
    /// Set when notifications cannot be delivered, so the menu can say so.
    private(set) var failure: String?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter raises for an unbundled binary. The CLI
        // never touches this file, but guard anyway.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Writes what actually happened into the shared preferences domain.
    ///
    /// A failure that only shows in a menu is a failure nobody can debug: the
    /// menu cannot be read from a script, from a log, or by anyone helping
    /// remotely. This is the seed of the diagnostics report on the roadmap.
    private func record(_ key: String, _ value: String) {
        Preferences.recordDiagnostic(key, value)
    }

    func readBackSettings() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            Task { @MainActor in
                let status: String
                switch settings.authorizationStatus {
                case .notDetermined: status = "notDetermined"
                case .denied: status = "denied"
                case .authorized: status = "authorized"
                case .provisional: status = "provisional"
                case .ephemeral: status = "ephemeral"
                @unknown default: status = "unknown"
                }
                self.record("authStatus", status)
                self.record("alertSetting", "\(settings.alertSetting.rawValue)")
                self.record("notificationCenterSetting", "\(settings.notificationCenterSetting.rawValue)")
            }
        }
    }

    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        record("bundleID", Bundle.main.bundleIdentifier ?? "nil")
        record("bundlePath", Bundle.main.bundlePath)
        guard let center else {
            failure = "Not running as a bundled app, so notifications are unavailable."
            record("requestOutcome", "no bundle identifier")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = granted
                if let error {
                    self.failure = "Notifications unavailable: \(error.localizedDescription)"
                    self.record("requestOutcome", "error: \(error.localizedDescription)")
                } else if granted {
                    self.failure = nil
                    self.record("requestOutcome", "granted")
                } else {
                    self.failure = "Notifications are off for DrivePark in System Settings."
                    self.record("requestOutcome", "denied")
                }
                self.readBackSettings()
            }
        }
    }

    func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.failure = "Notification failed: \(error.localizedDescription)"
                    self.record("lastPost", "error: \(error.localizedDescription)")
                } else {
                    self.record("lastPost", "accepted: \(title)")
                }
            }
        }
    }
}
