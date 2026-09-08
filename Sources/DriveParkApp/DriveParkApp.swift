// DriveParkApp — menu bar app over DriveParkKit. While this app runs after a
// full park, the remount veto stays armed; Mount drops it and remounts.

import SwiftUI
import AppKit
import os
import DriveParkKit

/// The one durable record of what a park did. The menu line and the notch
/// card are read once and gone; this survives in the unified log, so the
/// next question about where the time went has an answer instead of a guess.
///
///   log show --last 1h --predicate 'subsystem == "com.wiltonblake.drivepark"'
let parkLog = Logger(subsystem: "com.wiltonblake.drivepark", category: "park")

@main
struct DriveParkApp: App {
    @StateObject private var state = AppState()

    init() {
        // Before anything else, and before SwiftUI builds a scene. launchd
        // starts this same binary as the watchdog, and run() never returns, so
        // that process puts nothing in the menu bar. One binary, two jobs, and
        // they are never the same process. See Watchdog.swift for why the
        // watchdog is not its own executable.
        if AgentMode.isWatchdog { Watchdog.shared.run() }

        // Two copies means two menu bar icons and two things that each believe
        // they hold the park veto.
        if !SingleInstance.claim() { exit(0) }

        // Every orderly termination is a deliberate one: the Quit menu item,
        // Command-Q, an Apple Event from a script. The Quit button stamps this
        // too, and stamping twice costs nothing, but the button is not the only
        // way out and the watchdog must not resurrect an app a human closed.
        //
        // A crash, a kill -9, or a bundle replaced underneath the process runs
        // none of this, which is exactly the case the watchdog exists for. The
        // difference between "quit" and "died" is whether this line ran.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Preferences.noteQuitRequested()
            // The veto dies with this process, so the record of it must not
            // outlive it. A stale holder would make `park mount` wait on an
            // answer from a pid that is gone.
            VetoBroker.clearHold()
        }

        // `park mount` cannot lift a veto this process holds, because Disk
        // Arbitration dissent comes from the process that registered the
        // callback. So the CLI asks, and this is the ear. See VetoBroker.
        DistributedNotificationCenter.default().addObserver(
            forName: VetoBroker.mountRequested,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AppState.shared?.serveMountRequest() }
        }
        // An app update can change the watchdog agent, and launchd goes on
        // running the definition it was given until somebody registers the
        // new one. Nothing happens here in the ordinary case.
        LoginItem.reconcile()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(systemName: state.iconName)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// Set once at init so the cross-process mount request has something to
    /// call. The app is a single instance by construction (SingleInstance), so
    /// there is never a second one to point at.
    static weak var shared: AppState?

    @Published var disks: [PhysicalDisk] = []
    @Published var busy = false
    @Published var message = ""
    @Published var lastVerifiedAt: Date?
    @Published var enclosureStalled = false
    /// Guards the 30-second timer. Before diskutil calls had a timeout, a
    /// stalled enclosure made this timer stack a new hung child process every
    /// 30 seconds, forever, in silence.
    private var refreshing = false

    // Mirrors of persisted preferences, so SwiftUI sees the changes.
    @Published var enabledTriggers: Set<ParkTrigger> = Preferences.enabledTriggers
    @Published var autoMountOnWake: Bool = Preferences.autoMountOnWake
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    @Published var ignoredUUIDs: Set<String> = Preferences.ignoredVolumeUUIDs
    @Published var includeDiskImages: Bool = Preferences.includeDiskImages
    /// Live progress while a park runs. Counting up, never down: the measured
    /// unmount time is bimodal, half a second or eleven, so a countdown would
    /// be wrong a third of the time and you would learn to distrust it.
    /// Notch cards through Transom. Mirrored here so the menu can show the
    /// channel's real state, including when a post was refused.
    @Published var transomEnabled: Bool = Preferences.transomEnabled
    @Published var transomFailure: String?
    @Published var hotKeyEnabled: Bool = Preferences.hotKeyEnabled
    @Published var hotKeyDisplay: String = Preferences.hotKeyDisplay
    @Published var hotKeySystemConflict: String?
    /// Armed triggers that cannot currently fire, keyed by trigger.
    @Published var triggerWarnings: [ParkTrigger: String] = [:]
    /// Volumes the last park could not unmount, and who was holding them.
    /// Force is offered from here and nowhere else, so it can never be reached
    /// without a failure having already happened and been explained.
    @Published var lastBlocked: [VolumeParkResult] = []
    @Published var workingSince: Date?
    @Published var workingOn: String = ""
    private var tickTimer: Timer?

    let engine = Engine()
    private let triggers = TriggerCoordinator()
    private var timer: Timer?

    init() {
        AppState.shared = self
        refresh()
        Notifier.shared.requestAuthorizationIfNeeded()
        applyHotKey()
        triggers.state = self
        triggers.start()
        if let failure = triggers.powerWatchFailure { message = failure }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var allVolumes: [Volume] { disks.flatMap { $0.allVolumes } }
    /// Only the volumes DrivePark is allowed to act on. An ignored volume must
    /// not keep the tower reading "not parked" forever, and must not be
    /// counted as something still to do.
    var volumes: [Volume] { allVolumes.filter { !Preferences.isIgnored($0.uuid) } }
    var ignoredVolumes: [Volume] { allVolumes.filter { Preferences.isIgnored($0.uuid) } }
    var mountedCount: Int { volumes.filter { $0.isMounted }.count }
    var isParked: Bool { !volumes.isEmpty && mountedCount == 0 }

    var iconName: String {
        if enclosureStalled { return "externaldrive.badge.exclamationmark" }
        if volumes.isEmpty { return "externaldrive.badge.questionmark" }
        if isParked { return "externaldrive.badge.checkmark" }
        return "externaldrive"
    }

    var statusLine: String {
        if allVolumes.isEmpty { return "No external disks found" }
        if volumes.isEmpty { return "Every external volume is on the ignore list" }
        if !triggerWarnings.isEmpty {
            return "\(triggerWarnings.count) armed trigger(s) cannot fire"
        }
        if enclosureStalled { return "Enclosure not fully answering" }
        if isParked { return "Parked, safe to power off" }
        return "\(mountedCount) of \(volumes.count) volumes mounted"
    }

    var elapsedLine: String? {
        guard let workingSince else { return nil }
        let seconds = Int(Date().timeIntervalSince(workingSince).rounded())
        let what = workingOn.isEmpty ? "Working" : workingOn
        return "\(what), \(seconds)s  (usually under 2s, occasionally 11)"
    }

    /// The receipt. Every claim in this app traces to a fresh state read, and
    /// this is when the last one happened.
    var verifiedLine: String? {
        guard let lastVerifiedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Verified \(formatter.string(from: lastVerifiedAt))"
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let engine = self.engine
        Task.detached {
            let found = engine.discover()
            let stalled = DiskutilTimeout.occurred
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                // Heartbeat. Every trigger in this app depends on the app
                // being alive, and until now nothing anywhere said whether it
                // was. Absence is the one failure it could not report.
                Preferences.recordHeartbeat()
                self.enclosureStalled = stalled
                self.refreshing = false
                var warnings: [ParkTrigger: String] = [:]
                for status in TriggerHealth.armedButDead() {
                    warnings[status.trigger] = status.reason
                }
                self.triggerWarnings = warnings
                self.transomFailure = Transom.lastFailure
                if stalled, self.message.isEmpty || self.message.hasPrefix("Enclosure") {
                    self.message = "Enclosure not answering detail queries. Volume state is still accurate."
                }
            }
        }
    }

    // MARK: - Manual actions

    func triggersNoteManualPark() { triggers.noteManualPark() }

    /// Offered only after a manual park failed. Confirmed by a modal that
    /// names what is lost, then run once with no retries.
    func forceUnmountBlocked() {
        guard !busy, !lastBlocked.isEmpty else { return }
        let names = lastBlocked.map { $0.volume.displayName }
        let blockers = Array(Set(lastBlocked.flatMap { $0.blockers })).sorted()
        guard ForcePrompt.confirm(volumes: names, blockers: blockers) else {
            message = "Left alone. Nothing was forced."
            return
        }
        let disks = Set(lastBlocked.compactMap { volume -> String? in
            self.disks.first { $0.allVolumes.contains { $0.device == volume.volume.device } }?.device
        })
        triggers.noteManualPark()
        lastBlocked = []
        runPark(only: disks.isEmpty ? nil : disks, deadline: nil,
                label: nil, force: true, completion: nil)
    }

    var forceOfferLine: String? {
        guard !lastBlocked.isEmpty else { return nil }
        let names = lastBlocked.map { $0.volume.displayName }.joined(separator: ", ")
        return "Force unmount \(names)…"
    }

    func park(only: Set<String>? = nil, label: String? = nil) {
        triggers.noteManualPark()
        runPark(only: only, deadline: nil, label: label, completion: nil)
    }

    /// - Returns: false when it declined because something else is running.
    ///   Callers have to know, because a mount that quietly does nothing is
    ///   how the drives stayed parked after a wake on 2026-09-04.
    @discardableResult
    func mount(only: Set<String>? = nil, label: String? = nil) -> Bool {
        guard !busy else {
            Preferences.recordDiagnostic(
                "mount", "declined: a park or mount was already running")
            return false
        }
        busy = true
        message = "Mounting…"
        let engine = self.engine
        Task.detached {
            let outcome = engine.mount(onlyDisks: only)
            Self.record(outcome, trigger: label ?? "manual")
            let (mounted, total) = (outcome.mountedCount, outcome.total)
            let split = String(format: " %.1fs.", outcome.timing.total)
            let found = engine.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                self.busy = false
                if let label {
                    self.message = "\(label) back online." + split
                } else {
                    self.message = mounted == total
                        ? "All volumes back online." + split
                        : "\(mounted) of \(total) volumes mounted." + split
                }
            }
        }
        return true
    }

    // MARK: - Trigger-driven actions

    /// - Parameter completion: receives nil when no park was attempted, so a
    ///   caller holding sleep open can tell "done" from "never ran".
    func park(trigger: ParkTrigger, deadline: Date?,
              completion: ((ParkOutcome?) -> Void)?) {
        runPark(only: nil, deadline: deadline, label: nil,
                triggerLabel: trigger.reason, completion: completion)
    }

    func setIncludeDiskImages(_ on: Bool) {
        Preferences.includeDiskImages = on
        includeDiskImages = on
        // Discovery changes shape, so what is on screen is now stale. Re-read
        // rather than leaving the old list looking current.
        refresh()
        message = on
            ? "Disk images are now parkable drives."
            : "Disk images are no longer counted."
    }

    /// The wake path. Separate from the menu because a wake lands in the
    /// middle of things, and the sleep park it is undoing may still be running.
    ///
    /// The old version called mount once, ignored the answer, and set the
    /// message to "Remounted after the Mac woke" whether or not anything had
    /// been remounted. On 2026-09-04 that produced the worst possible pair: the
    /// drives stayed unmounted, the veto stayed armed, and the app said it had
    /// put them back. A tool that reports a remount it did not perform is
    /// exactly the thing this project exists to refuse.
    ///
    /// So it waits its turn instead. Six tries at five seconds is half a
    /// minute, which covers the slow end of a measured park, and running out
    /// says so rather than going quiet.
    func mount(reason: String) {
        guard mount(only: nil, label: nil) else {
            wakeMountAttempts += 1
            guard wakeMountAttempts <= 6 else {
                wakeMountAttempts = 0
                Preferences.recordDiagnostic(
                    "wake", "\(reason): still busy after 6 tries, drives left parked")
                message = "Could not mount after \(reason): something was still running."
                return
            }
            Preferences.recordDiagnostic(
                "wake", "\(reason): busy, retry \(wakeMountAttempts) in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.mount(reason: reason)
            }
            return
        }
        wakeMountAttempts = 0
        // No message here on purpose. The mount sets one when it finishes and
        // has counted what actually mounted.
        Preferences.recordDiagnostic("wake", "\(reason): mount started")
    }

    /// Bounded, so a permanently busy app cannot spin forever.
    private var wakeMountAttempts = 0

    /// Runs a mount asked for by `park mount` in another process, then
    /// answers with what a fresh read actually found. The CLI is waiting on
    /// that answer and will report a timeout rather than assume, so an
    /// unanswered request has to look like an unanswered request.
    func serveMountRequest() {
        guard let request = VetoBroker.pendingRequest() else { return }
        VetoBroker.consumeRequest()
        // Answer the doorbell before doing the work, so the CLI waits
        // instead of concluding that nobody is home.
        VetoBroker.acknowledge(nonce: request.nonce)
        busy = true
        message = "Mounting, asked by the command line…"
        let engine = self.engine
        Task.detached {
            let outcome = engine.mount(onlyDisks: request.disks)
            Self.record(outcome, trigger: "command line")
            let (mounted, total) = (outcome.mountedCount, outcome.total)
            let found = engine.discover()
            VetoBroker.answer(nonce: request.nonce, mounted: mounted, total: total)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                self.busy = false
                self.message = mounted == total
                    ? "All volumes back online, asked by the command line."
                    : "\(mounted) of \(total) volumes mounted."
            }
        }
    }

    private func runPark(only: Set<String>?, deadline: Date?, label: String?,
                         force: Bool = false,
                         triggerLabel: String? = nil,
                         completion: ((ParkOutcome?) -> Void)?) {
        guard !busy else {
            // Nothing was attempted. Report that, rather than an empty park
            // that would read as success.
            completion?(nil)
            return
        }
        busy = true
        message = force
            ? "Forcing…"
            : (triggerLabel.map { "Parking because \($0)…" } ?? "Parking…")
        startTicking()
        let engine = self.engine
        let before = volumes
        Task.detached {
            let outcome = engine.park(onlyDisks: only, deadline: deadline, force: force) { line in
                Task { @MainActor in self.workingOn = line }
            }
            Self.record(outcome, trigger: triggerLabel ?? label ?? "manual")
            let found = engine.discover()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = found
                self.lastVerifiedAt = Date()
                self.busy = false
                self.stopTicking()
                self.message = Self.describe(outcome, label: label, trigger: triggerLabel)
                // Trigger-driven parks never leave a force offer behind. A
                // failure you did not watch happen is not a mandate to do
                // something destructive later.
                self.lastBlocked = (triggerLabel == nil && !outcome.parked)
                    ? outcome.results.filter { !$0.success }
                    : []
                self.notify(outcome, scoped: only != nil, before: before)
            }
            completion?(outcome)
        }
    }

    private func startTicking() {
        workingSince = Date()
        workingOn = ""
        tickTimer?.invalidate()
        // Drives the elapsed readout. Counting up is a fact; counting down
        // would be a prediction this tool cannot honestly make.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        workingSince = nil
        workingOn = ""
    }

    /// Three outcomes, three different sentences, on three channels.
    ///
    /// The distinction that matters is partial versus whole: "Backup parked"
    /// must never read as "safe to undock" while two other drives are still
    /// mounted.
    ///
    /// Chime, banner, card. The chime is the only one that survives a locked
    /// screen, the banner is refused by macOS on this machine (SPEC section
    /// 10) and is still attempted in case that ever changes, and the card is
    /// the one you can actually read. Anything that means "do not pull the
    /// cable" is posted persistent, so it cannot time out while your hand is
    /// behind the desk.
    private func notify(_ outcome: ParkOutcome, scoped: Bool, before: [Volume]) {
        guard outcome.didWork || !outcome.parked else { return }

        if !outcome.parked {
            let names = outcome.stillMounted.map { $0.displayName }.joined(separator: ", ")
            var body = "Still mounted: \(names)."
            if let blockers = outcome.blockerSummary { body += " Blocked by \(blockers)." }
            Notifier.shared.post(title: "Park failed", body: body)
            Transom.post(title: "Park failed, do not undock",
                         message: body,
                         symbol: "externaldrive.trianglebadge.exclamationmark",
                         persistent: true,
                         urgent: true)
            Chime.failed.play()
            return
        }

        let parkedNames = outcome.results.filter { $0.success }
            .map { $0.volume.displayName }
        let seconds = String(format: "%.1fs", outcome.timing.total)

        if isParked {
            // Everything DrivePark manages is unmounted. Only now is the
            // undock question even askable.
            let stillMountedIgnored = ignoredVolumes.filter { $0.isMounted }
            if stillMountedIgnored.isEmpty {
                Notifier.shared.post(
                    title: "Tower parked, safe to unplug",
                    body: "\(parkedNames.count) volume(s) verified unmounted in \(seconds).")
                // Urgent, and it took a real complaint to get here. Wekesa
                // runs Transom filtered to VIPs, codes and urgent, so this card
                // was being held, which is the worst one to hold: it is the
                // only card you ACT on. The failure cards tell you to keep your
                // hands off, and doing nothing is the safe default you would
                // have taken anyway. This is the one that says the waiting is
                // over, and a "safe to undock" that arrives after you have
                // already walked away is the same as no card at all.
                //
                // Still ten seconds rather than persistent. It is not a warning
                // and it should not need dismissing.
                Transom.post(
                    title: "Safe to undock",
                    message: "\(parkedNames.count) volume(s) verified unmounted in \(seconds). "
                        + "Pull the cable.",
                    symbol: "externaldrive.badge.checkmark",
                    duration: 10,
                    urgent: true)
                // The one sound that means "pull the cable". Nothing else uses it.
                Chime.safeToUnplug.play()
            } else {
                let names = stillMountedIgnored.map { $0.displayName }.joined(separator: ", ")
                Notifier.shared.post(
                    title: "Tower parked, but not safe to unplug",
                    body: "\(names) is on the ignore list and still mounted. Verified in \(seconds).")
                // Persistent on purpose. This one looks like success in the
                // menu bar icon and is not, and a card that fades in six
                // seconds is how a mounted drive gets yanked.
                Transom.post(
                    title: "Parked, but do NOT undock",
                    message: "\(names) is on the ignore list and still mounted. "
                        + "Verified in \(seconds).",
                    symbol: "exclamationmark.triangle.fill",
                    persistent: true,
                    urgent: true)
                Chime.partial.play()
            }
        } else {
            let names = parkedNames.joined(separator: ", ")
            Notifier.shared.post(
                title: names.isEmpty ? "Parked" : "\(names) parked",
                body: "\(mountedCount) of \(volumes.count) volumes still mounted. Not safe to unplug yet.")
            Transom.post(
                title: names.isEmpty ? "Parked" : "\(names) parked",
                message: "\(mountedCount) of \(volumes.count) volumes still mounted. "
                    + "Not safe to undock yet.",
                symbol: "externaldrive",
                duration: 10,
                urgent: true)
            Chime.partial.play()
        }
    }

    /// Writes the timing split and every volume's verdict to the unified log.
    /// Public values only: volume names, device nodes, seconds, attempt counts.
    nonisolated private static func record(_ outcome: ParkOutcome, trigger: String) {
        guard outcome.didWork else {
            parkLog.info("park (\(trigger, privacy: .public)): nothing to do")
            return
        }
        parkLog.info("park (\(trigger, privacy: .public)): \(outcome.timing.summary, privacy: .public)")
        for result in outcome.results {
            let verdict = result.success ? "unmounted" : "FAILED"
            let line = String(format: "%@ (%@): %@ in %.2fs, %d attempt(s)",
                              result.volume.displayName, result.volume.device,
                              verdict, result.duration, result.attempts)
            parkLog.info("  \(line, privacy: .public)")
        }
        for note in outcome.notes {
            parkLog.info("  \(note, privacy: .public)")
        }
    }

    nonisolated private static func record(_ outcome: MountOutcome, trigger: String) {
        guard !outcome.results.isEmpty else {
            parkLog.info("mount (\(trigger, privacy: .public)): nothing to do")
            return
        }
        parkLog.info("mount (\(trigger, privacy: .public)): \(outcome.summary, privacy: .public)")
        for result in outcome.results {
            let verdict = result.success ? "mounted" : "FAILED \(result.detail ?? "")"
            let line = String(format: "%@ (%@): %@ in %.2fs",
                              result.volume.displayName, result.volume.device,
                              verdict, result.duration)
            parkLog.info("  \(line, privacy: .public)")
        }
    }

    private static func describe(_ outcome: ParkOutcome, label: String?,
                                 trigger: String?) -> String {
        if outcome.parked && !outcome.didWork {
            return "No action taken. Nothing this run manages was mounted."
        }
        if outcome.parked {
            // The split rides along on the menu line so the answer to "why did
            // that take so long" is one click away, not a log query.
            let split = String(format: " %.1fs: unmount %.1f, spin-down %.1f.",
                               outcome.timing.total, outcome.timing.unmount,
                               outcome.timing.spinDown)
            if let label { return "\(label) parked." + split }
            if let trigger { return "Parked because \(trigger). Safe to power off." + split }
            return "Parked. Safe to power off the tower." + split
        }
        let names = outcome.stillMounted.map { $0.displayName }.joined(separator: ", ")
        var text = "Not parked. Still mounted: \(names)."
        if let blockers = outcome.blockerSummary { text += " Blocked by \(blockers)." }
        return text
    }

    // MARK: - Settings

    func setTrigger(_ trigger: ParkTrigger, _ on: Bool) {
        Preferences.setEnabled(trigger, on)
        enabledTriggers = Preferences.enabledTriggers
        let status = TriggerHealth.status(for: trigger)
        if on, !status.canFire, let reason = status.reason {
            // Say it at the moment they switch it on, not only in a submenu
            // they may never open again.
            message = reason
            triggerWarnings[trigger] = reason
        } else {
            triggerWarnings[trigger] = nil
        }
    }

    func setAutoMount(_ on: Bool) {
        Preferences.autoMountOnWake = on
        autoMountOnWake = on
    }

    func setIgnored(_ volume: Volume, _ on: Bool) {
        guard let uuid = volume.uuid else {
            message = "\(volume.displayName) has no volume UUID, so it cannot be tracked across replugs."
            return
        }
        Preferences.setIgnored(uuid, on)
        ignoredUUIDs = Preferences.ignoredVolumeUUIDs
        message = on
            ? "\(volume.displayName) is ignored. DrivePark will not unmount it."
            : "\(volume.displayName) is managed again."
        objectWillChange.send()
    }

    /// One keystroke, both directions. Park when anything is mounted, mount
    /// when everything is parked. The chimes tell the two apart, which is why
    /// a toggle is safe here: you always hear which way it went.
    func hotKeyPressed() {
        guard !busy, !volumes.isEmpty else { return }
        triggers.noteManualPark()
        if isParked {
            mount()
        } else {
            park()
        }
    }

    func openShortcutRecorder() {
        ShortcutRecorder.shared.onSaved = { [weak self] in
            guard let self else { return }
            self.hotKeyDisplay = Preferences.hotKeyDisplay
            self.applyHotKey()
            self.message = HotKeyCenter.shared.isRegistered
                ? "Shortcut is \(Preferences.hotKeyDisplay)."
                : (HotKeyCenter.shared.failure ?? "Shortcut unavailable.")
        }
        ShortcutRecorder.shared.show()
    }

    func applyHotKey() {
        if Preferences.hotKeyEnabled {
            HotKeyCenter.shared.action = { [weak self] in self?.hotKeyPressed() }
            if !HotKeyCenter.shared.register(), let failure = HotKeyCenter.shared.failure {
                message = failure
            }
        } else {
            HotKeyCenter.shared.unregister()
        }
        hotKeyEnabled = Preferences.hotKeyEnabled
        hotKeyDisplay = Preferences.hotKeyDisplay
        // Readable from outside the app, so the shortcut can be checked
        // without opening a menu nobody else can see.
        // Registration success is not proof it fires. A shortcut the system
        // owns registers fine and is then eaten before we see it.
        if Preferences.hotKeyEnabled,
           let owner = SystemShortcuts.owner(keyCode: Preferences.hotKeyCode,
                                             carbonModifiers: Preferences.hotKeyModifiers) {
            hotKeySystemConflict = "\(Preferences.hotKeyDisplay) belongs to \(owner), so it will never fire."
        } else {
            hotKeySystemConflict = nil
        }
        Preferences.recordDiagnostic("hotKeyConflict", hotKeySystemConflict ?? "none")
        Preferences.recordDiagnostic("hotKey", Preferences.hotKeyEnabled
            ? "\(Preferences.hotKeyDisplay) code=\(Preferences.hotKeyCode) "
                + "mods=\(Preferences.hotKeyModifiers) "
                + (HotKeyCenter.shared.isRegistered ? "REGISTERED" : "FAILED")
            : "disabled")
    }

    func setHotKeyEnabled(_ on: Bool) {
        Preferences.hotKeyEnabled = on
        applyHotKey()
        if on, HotKeyCenter.shared.isRegistered {
            message = "\(HotKeyCenter.displayName) parks the tower, and mounts it when parked."
        } else if !on {
            message = "Global shortcut off."
        }
    }

    var hotKeyLine: String {
        if !Preferences.hotKeyEnabled { return "Global shortcut: off" }
        if let conflict = hotKeySystemConflict { return "⚠︎ \(conflict)" }
        if HotKeyCenter.shared.isRegistered {
            return "Global shortcut: \(HotKeyCenter.displayName)"
        }
        return HotKeyCenter.shared.failure ?? "Global shortcut: unavailable"
    }

    func setTransomEnabled(_ on: Bool) {
        Preferences.transomEnabled = on
        transomEnabled = on
        message = on
            ? "Park results will post a card to the Transom notch."
            : "Notch cards off. Chimes still play."
        if on { testTransom() }
    }

    func askForTransomToken() {
        guard let answer = TokenPrompt.ask(current: Preferences.transomToken) else { return }
        if answer == .some(TokenPrompt.readFromKeychain) {
            // Explicit, so the modal Keychain prompt lands while the user is
            // already looking at a dialog, never in the middle of a park.
            Task.detached {
                let found = Transom.keychainToken()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let found else {
                        self.message = "Nothing readable in the Keychain. "
                            + "Copy the token from Transom → Advanced → Local API instead."
                        return
                    }
                    Preferences.transomToken = found
                    Transom.forgetCachedToken()
                    self.testTransom()
                }
            }
            return
        }
        Preferences.transomToken = answer
        Transom.forgetCachedToken()
        guard answer != nil else {
            transomFailure = nil
            message = "Transom token cleared."
            return
        }
        // Prove it before saying it works. A saved token that 401s is a
        // channel that looks configured and delivers nothing.
        testTransom()
    }

    /// Posts a real card rather than reporting on configuration. A channel
    /// that has not carried a message is not a channel that works.
    func testTransom() {
        Task.detached {
            let delivered = Transom.postAndWait(
                title: "DrivePark connected",
                message: "Park results will land here.",
                symbol: "externaldrive.badge.checkmark",
                duration: 6)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transomFailure = Transom.lastFailure
                self.message = delivered
                    ? "Test card posted to the notch."
                    : (Transom.lastFailure ?? "Test card was not delivered.")
            }
        }
    }

    var transomLine: String {
        if !transomEnabled { return "Notch cards: off" }
        if let transomFailure { return "⚠︎ \(transomFailure)" }
        return Transom.statusLine
    }

    func setLaunchAtLogin(_ on: Bool) {
        if let failure = LoginItem.setEnabled(on) {
            message = failure
        } else {
            message = on
                ? "DrivePark will start at login and restart if it dies."
                : "Keep-running is off."
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

private extension ParkTrigger {
    var reason: String {
        switch self {
        case .systemSleep: return "the Mac is going to sleep"
        case .displaySleep: return "the displays turned off"
        case .screenLock: return "the screen locked"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        if let elapsed = state.elapsedLine {
            Text(elapsed)
        } else if let verified = state.verifiedLine {
            Text(verified)
        }
        Divider()
        ForEach(state.disks, id: \.device) { disk in
            let actionable = disk.allVolumes.filter { !Preferences.isIgnored($0.uuid) }
            let mountedHere = actionable.contains { $0.isMounted }
            let label = disk.allVolumes.map { $0.displayName }.joined(separator: ", ")
            if actionable.isEmpty {
                Text("\(label) — ignored")
            } else {
                Button(mountedHere ? "Park \(label)" : "Mount \(label)") {
                    if mountedHere {
                        state.park(only: [disk.device], label: label)
                    } else {
                        state.mount(only: [disk.device], label: label)
                    }
                }
                .disabled(state.busy)
            }
        }
        Divider()
        Button(state.busy ? "Working…" : "Park Tower") {
            state.triggersNoteManualPark()
            state.park()
        }

        .disabled(state.busy || state.isParked || state.volumes.isEmpty)
        Button("Mount Tower") {
            state.mount()
        }
        .disabled(state.busy || state.volumes.isEmpty || state.mountedCount == state.volumes.count)

        if let offer = state.forceOfferLine {
            Divider()
            Button(offer) { state.forceUnmountBlocked() }
                .disabled(state.busy)
        }
        Divider()
        Menu("Drives") {
            Text("Unchecked drives are never touched, including by Park Tower")
            Divider()
            Toggle("Include mounted disk images", isOn: Binding(
                get: { state.includeDiskImages },
                set: { state.setIncludeDiskImages($0) }))
            Text(state.includeDiskImages
                 ? "A .dmg now counts, so Park Tower waits for it too"
                 : "A .dmg being open will not change the safe-to-unplug answer")
            Divider()
            ForEach(state.allVolumes, id: \.device) { volume in
                Toggle(volume.displayName.isEmpty ? volume.device : volume.displayName,
                       isOn: Binding(
                        get: { !Preferences.isIgnored(volume.uuid) },
                        set: { state.setIgnored(volume, !$0) }))
                    .disabled(volume.uuid == nil)
            }
        }
        Menu("Automation") {
            ForEach(ParkTrigger.allCases, id: \.self) { trigger in
                Toggle(trigger.label, isOn: Binding(
                    get: { state.enabledTriggers.contains(trigger) },
                    set: { state.setTrigger(trigger, $0) }))
                // The honest bit. A ticked box that cannot fire says so here,
                // instead of letting you believe you are covered.
                if let reason = state.triggerWarnings[trigger] {
                    Text("⚠︎ \(reason)")
                }
            }
            Divider()
            Toggle("Mount automatically on wake", isOn: Binding(
                get: { state.autoMountOnWake },
                set: { state.setAutoMount($0) }))
            Divider()
            Toggle("Keep DrivePark running (start at login, restart if it dies)", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }))
            Divider()
            Text(state.transomLine)
            Toggle("Post park results to the Transom notch", isOn: Binding(
                get: { state.transomEnabled },
                set: { state.setTransomEnabled($0) }))
            Button("Send a test card") { state.testTransom() }
                .disabled(!state.transomEnabled)
            Button("Set Transom token…") { state.askForTransomToken() }
            Divider()
            Text(state.hotKeyLine)
            Toggle("Global shortcut", isOn: Binding(
                get: { state.hotKeyEnabled },
                set: { state.setHotKeyEnabled($0) }))
            Button("Change shortcut (\(state.hotKeyDisplay))…") {
                state.openShortcutRecorder()
            }
            .disabled(!state.hotKeyEnabled)
        }

        if !state.message.isEmpty {
            Divider()
            Text(state.message)
        }
        Divider()
        Button("Refresh") { state.refresh() }
        Button("Quit DrivePark") {
            // Tell the watchdog this was deliberate before going. Without
            // the stamp it does its job and brings the app straight back,
            // which is what malware does.
            Preferences.noteQuitRequested()
            NSApp.terminate(nil)
        }
            .keyboardShortcut("q")
    }
}
