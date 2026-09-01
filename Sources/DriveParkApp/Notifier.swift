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

    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        guard let center else {
            failure = "Not running as a bundled app, so notifications are unavailable."
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = granted
                if let error {
                    self.failure = "Notifications unavailable: \(error.localizedDescription)"
                } else if granted {
                    self.failure = nil
                } else {
                    self.failure = "Notifications are off for DrivePark in System Settings."
                }
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
            guard let error else { return }
            Task { @MainActor in
                self?.failure = "Notification failed: \(error.localizedDescription)"
            }
        }
    }
}
