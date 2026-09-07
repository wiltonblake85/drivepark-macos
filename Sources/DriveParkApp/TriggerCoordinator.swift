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
// Auto-mount only ever undoes an auto-park. A drive the user parked by hand
// stays parked through a wake cycle, because they had a reason.

import Foundation
import AppKit
import DriveParkKit

@MainActor
final class TriggerCoordinator {
    private let powerWatch = PowerWatch()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingMount: DispatchWorkItem?

    /// True only when the most recent park came from a trigger, not a click.
    ///
    /// Backed by preferences rather than a field, so it survives the app being
    /// restarted between the park and the wake. See Preferences.parkedByTrigger
    /// for what that cost on 2026-09-04.
    var parkedByTrigger: Bool {
        get { Preferences.parkedByTrigger }
        set { Preferences.parkedByTrigger = newValue }
    }

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
                MainActor.assumeIsolated { self?.fire(.screenLock) }
            })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake(reason: "the screen unlocked") }
            })
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

        parkedByTrigger = true
        Preferences.recordDiagnostic("wakeArm", "systemSleep park, parkedByTrigger set")
        state.park(trigger: .systemSleep, deadline: deadline) { _ in allow() }
    }

    private func fire(_ trigger: ParkTrigger) {
        guard Preferences.isEnabled(trigger), let state, !state.volumes.isEmpty else { return }
        guard !state.isParked else { return }
        pendingMount?.cancel()
        parkedByTrigger = true
        Preferences.recordDiagnostic("wakeArm", "\(trigger.rawValue) park, parkedByTrigger set")
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
        guard parkedByTrigger else {
            Preferences.recordDiagnostic(
                "wake", "\(reason): the park did not come from a trigger, leaving it parked")
            return
        }
        guard state != nil else {
            Preferences.recordDiagnostic("wake", "\(reason): no app state")
            return
        }
        Preferences.recordDiagnostic("wake", "\(reason): mounting in \(Int(Preferences.wakeMountDelay))s")
        pendingMount?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let state = self.state else { return }
                self.parkedByTrigger = false
                Preferences.recordDiagnostic("wake", "\(reason): mount running now")
                state.mount(reason: reason)
            }
        }
        pendingMount = work
        // Docks and multi-bay bridges re-enumerate slowly. Mounting into that
        // window fails, and a failed remount reads as a broken app.
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.wakeMountDelay,
                                      execute: work)
    }

    /// A manual park should not be undone by the next wake.
    func noteManualPark() {
        parkedByTrigger = false
        pendingMount?.cancel()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }
}
