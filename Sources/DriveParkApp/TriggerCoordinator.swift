// TriggerCoordinator.swift — turns machine events into parks.
//
// Three sources, deliberately not one:
//   system sleep   IOKit, because it is the only one that holds sleep open
//                  while the park finishes. NSWorkspace.willSleep would tell
//                  us sleep is happening and give us no time to act on it.
//   displays off   NSWorkspace screensDidSleep.
//   screen lock    a distributed notification. Undocumented by Apple but
//                  stable for years; if it ever stops firing the other two
//                  triggers are unaffected.
//
// Auto-mount only ever undoes an auto-park, volume by volume. A drive the user
// parked by hand stays parked through a wake cycle, because they had a reason.
// AppState records what each automatic park took down
// (Preferences.triggerParkedVolumeUUIDs) and takes volumes back out of that
// record when a person parks or mounts them.

import Foundation
import AppKit
import DriveParkKit

@MainActor
final class TriggerCoordinator {
    private let powerWatch = PowerWatch()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingMount: DispatchWorkItem?

    weak var state: AppState?

    /// Set when IOKit registration fails, so the menu can say so out loud.
    private(set) var powerWatchFailure: String?

    func start() {
        if !powerWatch.start() {
            powerWatchFailure = "Sleep trigger unavailable: could not register for system power notifications."
        }

        powerWatch.onWillSleep = { [weak self] allow in
            MainActor.assumeIsolated {
                self?.handleWillSleep(allow: allow)
            }
        }
        powerWatch.onDidWake = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleWake(reason: "the Mac woke")
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.fire(.displaySleep)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.handleWake(reason: "the displays came back")
        }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.whenSession(isLocked: true, notice: "a screen lock notice") {
                        self?.fire(.screenLock)
                    }
                }
            })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.whenSession(isLocked: false, notice: "a screen unlock notice") {
                        self?.handleWake(reason: "the screen unlocked")
                    }
                }
            })
    }

    /// Whether this login session's screen is locked, as the window server
    /// sees it, or nil when that cannot be read.
    static func sessionScreenIsLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Acts on a lock or unlock notice only when the session agrees.
    ///
    /// The notices are distributed notifications, and any process can post
    /// one (audit, Low). This session's own tests did exactly that on
    /// 2026-10-06 to drive a park and a wake without locking the screen. So
    /// the window server is asked as well, four times over a second and a
    /// half in case the notice lands before the session state turns. When the
    /// session cannot be read at all, the notice is trusted as it always was,
    /// rather than leaving a real screen lock unanswered.
    private func whenSession(isLocked expected: Bool, notice: String,
                             _ action: @escaping () -> Void) {
        Task { @MainActor in
            for attempt in 0..<4 {
                guard let locked = Self.sessionScreenIsLocked() else { return action() }
                if locked == expected { return action() }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            Preferences.recordDiagnostic(
                "screenLock",
                "\(notice) arrived but the screen is \(expected ? "not locked" : "still locked"); ignored")
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    /// Sleep is held open until `allow` runs. Two things can call it: the park
    /// finishing, and the budget expiring. Whichever is first wins; PowerWatch
    /// makes the second call a no-op.
    private func handleWillSleep(allow: @escaping () -> Void) {
        guard Preferences.isEnabled(.systemSleep), let state, !state.volumes.isEmpty else {
            allow()
            return
        }
        pendingMount?.cancel()
        let budget = Preferences.sleepParkBudget
        let deadline = Date().addingTimeInterval(budget)

        // Hard backstop. If the park hangs on a dissent that never resolves,
        // the Mac still sleeps on schedule instead of stalling at the lid.
        DispatchQueue.global().asyncAfter(deadline: .now() + budget + 2) { allow() }

        Preferences.recordDiagnostic("wakeArm", "systemSleep park started")
        state.park(trigger: .systemSleep, deadline: deadline) { _ in allow() }
    }

    private func fire(_ trigger: ParkTrigger) {
        guard Preferences.isEnabled(trigger), let state, !state.volumes.isEmpty else { return }
        guard !state.nothingToPark else { return }
        pendingMount?.cancel()
        Preferences.recordDiagnostic("wakeArm", "\(trigger.rawValue) park started")
        state.park(trigger: trigger, deadline: nil, completion: nil)
    }

    private func handleWake(reason: String) {
        // Say why nothing happened. On 2026-09-04 a real sleep parked the tower
        // and the wake mounted nothing, and there was no way to tell from
        // outside whether the notification never arrived or a guard declined
        // it. A trigger that silently does not fire is the failure this app
        // exists to refuse, so it now reports which of the three it was.
        guard Preferences.autoMountOnWake else {
            Preferences.recordDiagnostic("wake", "\(reason): auto-mount is off")
            return
        }
        guard let state else {
            Preferences.recordDiagnostic("wake", "\(reason): no app state")
            return
        }
        // An automatic park still running counts: a wake that lands during it
        // waits for it, then mounts what it took down.
        guard state.triggerParkRunning
                || !Preferences.triggerParkedVolumeUUIDs.isEmpty
                || Preferences.legacyParkedByTrigger else {
            Preferences.recordDiagnostic(
                "wake", "\(reason): nothing an automatic park took down is waiting, leaving any parked drive parked")
            return
        }
        Preferences.recordDiagnostic("wake", "\(reason): mounting in \(Int(Preferences.wakeMountDelay))s")
        pendingMount?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let state = self.state else { return }
                Preferences.recordDiagnostic("wake", "\(reason): mount running now")
                state.mountAfterWake(reason: reason)
            }
        }
        pendingMount = work
        // Docks and multi-bay bridges re-enumerate slowly. Mounting into that
        // window fails, and a failed remount reads as a broken app.
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.wakeMountDelay,
                                      execute: work)
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }
}
