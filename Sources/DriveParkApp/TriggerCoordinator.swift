// TriggerCoordinator.swift — turns machine events into parks.
//
// Three sources, deliberately not one:
//   system sleep   IOKit, because it is the only one that holds sleep open
//                  while the park finishes. NSWorkspace.willSleep would tell
//                  us sleep is happening and give us no time to act on it.
//   displays off   NSWorkspace screensDidSleep.
//   screen lock    a distributed notification. Undocumented by Apple but
//                  stable for years; if it ever stops firing the other two
//                  triggers are unaffected. Any process can post it, so it
//                  only counts once the login session says the screen is
//                  locked (ScreenLock).
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
                    self?.confirm(locked: true) { $0.fire(.screenLock) }
                }
            })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.confirm(locked: false) { $0.handleWake(reason: "the screen unlocked") }
                }
            })
    }

    /// Acts on a lock or unlock notice only once the login session agrees.
    /// A post from some other process with the screen in the other state is
    /// recorded and dropped: no park, no mount.
    private func confirm(locked: Bool, attempt: Int = 0,
                         then action: @escaping (TriggerCoordinator) -> Void) {
        if ScreenLock.isLockedNow == locked {
            action(self)
            return
        }
        let times = ScreenLock.checkTimes
        guard attempt + 1 < times.count else {
            Preferences.recordDiagnostic(
                "screenLock", "\(locked ? "lock" : "unlock") notice at \(Date()), but the session said "
                    + "\(locked ? "unlocked" : "locked") for \(times.last ?? 0)s: ignored")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + times[attempt + 1] - times[attempt]) { [weak self] in
            MainActor.assumeIsolated { self?.confirm(locked: locked, attempt: attempt + 1, then: action) }
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
