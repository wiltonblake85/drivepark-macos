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
/// Written at notice level. It was info until 2026-10-06, and macOS keeps a
/// third-party subsystem's info lines in memory only: the query below found
/// nothing at all for a park that had just run, so the record this comment
/// promised did not exist. (In zsh, `log` is a builtin; call /usr/bin/log.)
///
///   /usr/bin/log show --last 1h --predicate 'subsystem == "com.wiltonblake.drivepark"'
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
            if state.safeToPowerOff {
                Image(nsImage: SafeMark.image)
            } else {
                Image(systemName: state.iconName)
            }
        }
    }
}

/// The checkmark, sized to be read from across the desk.
///
/// It used to be a badge in the corner of the drive glyph, a few points
/// across, and the one icon state you act on looked almost the same as the
/// ones that mean keep your hands off. Now the whole slot is a bold check,
/// and it appears only when safeToPowerOff is true. Every other state keeps
/// the small drive glyph, so the difference is the shape of the icon, not a
/// detail inside it.
///
/// A plain template check, drawn in the same white as every other icon in
/// the menu bar. A green filled circle was tried first, then a white one,
/// and both stood out more than a menu bar icon should.
enum SafeMark {
    static let image: NSImage = {
        let symbol = NSImage(systemSymbolName: "checkmark",
                             accessibilityDescription: "Safe to power off")
            ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class AppState: ObservableObject {
    /// Set once at init so the cross-process mount request has something to
    /// call. The app is a single instance by construction (SingleInstance), so
    /// there is never a second one to point at.
    static weak var shared: AppState?

    @Published var disks: [PhysicalDisk] = []
    /// Mounts the kernel reports that the last read could not account for.
    @Published var unaccountedMounts: [UnaccountedMount] = []
    /// Set when the last read did not finish. Nothing on screen is verified
    /// while this is set, and the icon never shows the checkmark.
    @Published var readFailure: String?
    @Published var busy = false {
        didSet {
            // A disk changed while a park or a mount had the floor. Its own
            // verifying read may already cover it, but one more read is cheap
            // and an unnoticed mount is not.
            if oldValue, !busy, refreshOwed { refresh() }
        }
    }
    @Published var message = ""
    @Published var lastVerifiedAt: Date?
    @Published var lastFailedReadAt: Date?
    @Published var enclosureStalled = false
    /// Guards against overlapping reads. Before diskutil calls had a timeout,
    /// a stalled enclosure made the refresh timer stack a new hung child
    /// process every 30 seconds, forever, in silence.
    private var refreshing = false
    /// A read was asked for while another read, a park or a mount was
    /// running. It happens as soon as that finishes, rather than being lost.
    private var refreshOwed = false

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
    /// When that list was made. It used to never expire (audit H4).
    private var lastBlockedAt: Date?
    /// Long enough to go and quit the program the failure named and come
    /// back; short enough that nobody forces on a failure they no longer
    /// remember the details of.
    static let forceOfferLifetime: TimeInterval = 300
    @Published var workingSince: Date?
    @Published var workingOn: String = ""
    private var tickTimer: Timer?

    let engine = Engine()
    private let triggers = TriggerCoordinator()
    private var timer: Timer?
    private let diskEvents = DiskEvents()

    /// The backstop read. Disk Arbitration's events drive the reads now; this
    /// catches what they cannot, an enclosure that stops answering without
    /// anything appearing or disappearing, and the power assertions behind
    /// the trigger warnings. It was every 30 s, around 17,000 process
    /// launches a day on an idle Mac (audit, Low).
    static let backstopInterval: TimeInterval = 300

    init() {
        AppState.shared = self
        refresh()
        Notifier.shared.requestAuthorizationIfNeeded()
        applyHotKey()
        triggers.state = self
        triggers.start()
        if let failure = triggers.powerWatchFailure { message = failure }
        if let gaveUp = Preferences.watchdogGaveUpAt {
            message = Watchdog.gaveUpSentence(at: gaveUp)
            Preferences.watchdogGaveUpAt = nil
        }
        let timer = Timer(timeInterval: Self.backstopInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if let diskEvents {
            diskEvents.start { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            // Without events, the backstop is the only way a new mount is
            // seen, so say how slow that is.
            message = "Disk Arbitration events unavailable: new mounts show up within 5 minutes."
        }
    }

    var allVolumes: [Volume] { disks.flatMap { $0.allVolumes } }
    /// Only the volumes DrivePark is allowed to act on. An ignored volume must
    /// not be counted as something still to do.
    var volumes: [Volume] { allVolumes.filter { !Preferences.isIgnored($0.uuid) } }
    var mountedCount: Int { volumes.filter { $0.isMounted }.count }
    /// Managed volumes the remount veto cannot hold, because it matches on a
    /// volume UUID they do not have. A park unmounts them; nothing keeps them
    /// unmounted, and the menu says so (audit, Low).
    var unholdableVolumes: [Volume] { volumes.filter { $0.uuid == nil } }
    /// Nothing DrivePark manages is mounted, so a park would do nothing.
    ///
    /// Decides what the menu offers and which way the shortcut goes. It is not
    /// a safety claim: an ignored volume can still be mounted. That used to be
    /// called isParked and drove the checkmark (audit H1).
    var nothingToPark: Bool { mountedCount == 0 }

    private var verdict: PowerOffVerdict {
        PowerOffVerdict(disks: disks, unaccountedMounts: unaccountedMounts)
    }

    /// The one answer: the last read finished, it found something, and nothing
    /// on any external disk is mounted, managed or ignored, with no mount the
    /// kernel reports that the read could not account for. The icon, the
    /// status line and the menu all read this.
    var safeToPowerOff: Bool {
        readFailure == nil
            && !(allVolumes.isEmpty && unaccountedMounts.isEmpty)
            && verdict.safeToPowerOff
    }

    var safetyReason: String? {
        if let readFailure { return "could not verify: \(readFailure)" }
        return verdict.reason(isIgnored: Preferences.isIgnored)
    }

    var iconName: String {
        if readFailure != nil { return "externaldrive.badge.exclamationmark" }
        if allVolumes.isEmpty && unaccountedMounts.isEmpty { return "externaldrive.badge.questionmark" }
        if safeToPowerOff { return "externaldrive.badge.checkmark" }
        return "externaldrive"
    }

    var statusLine: String {
        if readFailure != nil {
            return enclosureStalled ? "Enclosure not answering, cannot verify"
                                    : "Could not read the disks, cannot verify"
        }
        if allVolumes.isEmpty && unaccountedMounts.isEmpty { return "No external disks found" }
        if !triggerWarnings.isEmpty {
            return "\(triggerWarnings.count) armed trigger(s) cannot fire"
        }
        if safeToPowerOff { return "Parked, safe to power off" }
        if nothingToPark, let reason = safetyReason { return "Not safe to power off: \(reason)" }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        if readFailure != nil, let lastFailedReadAt {
            return "Last read failed at \(formatter.string(from: lastFailedReadAt))"
        }
        guard let lastVerifiedAt else { return nil }
        return "Verified \(formatter.string(from: lastVerifiedAt))"
    }

    /// Puts a read on screen. A read that did not finish clears nothing it
    /// cannot replace: the drive list stays as it was, marked unverified, and
    /// the checkmark goes.
    private func apply(_ read: Result<DiskSnapshot, Error>) {
        switch read {
        case .success(let snapshot):
            disks = snapshot.disks
            unaccountedMounts = snapshot.unaccountedMounts
            readFailure = nil
            enclosureStalled = false
            lastVerifiedAt = Date()
        case .failure(let error):
            let failure = error as? DiscoveryFailure
            if let partial = failure?.partial, !partial.isEmpty { disks = partial }
            unaccountedMounts = []
            readFailure = failure?.reason ?? "\(error)"
            enclosureStalled = failure?.timedOut ?? false
            lastFailedReadAt = Date()
        }
        pruneForceOffer()
    }

    func refresh() {
        // Not during a park or a mount: a read that starts before one finishes
        // and lands after it would put an older state over the verified one.
        // Owed instead, so a disk that changed in the meantime is still read.
        guard !refreshing, !busy else {
            refreshOwed = true
            return
        }
        refreshing = true
        refreshOwed = false
        let engine = self.engine
        Task.detached {
            let read = Result { try engine.discover() }
            // A volume put on the ignore list from the CLI is no longer this
            // app's to hold down either.
            engine.liftVetoForIgnored()
            // Asks powerd, which answers slowest exactly around sleep and
            // wake. It used to run inside MainActor.run below, with pmset
            // behind it, and froze the menu for up to five seconds (audit,
            // Medium). Off the main actor, the menu never waits on it.
            var warnings: [ParkTrigger: String] = [:]
            for status in TriggerHealth.armedButDead() {
                warnings[status.trigger] = status.reason
            }
            await MainActor.run { [weak self, warnings] in
                guard let self else { return }
                self.apply(read)
                // Heartbeat. Every trigger in this app depends on the app
                // being alive, and until now nothing anywhere said whether it
                // was. Absence is the one failure it could not report.
                Preferences.recordHeartbeat()
                self.refreshing = false
                self.triggerWarnings = warnings
                self.transomFailure = Transom.lastFailure
                if self.enclosureStalled, self.message.isEmpty || self.message.hasPrefix("Enclosure") {
                    self.message = "Enclosure not answering. Nothing can be verified until it does."
                }
                // A disk changed after this read began.
                if self.refreshOwed, !self.busy { self.refresh() }
            }
        }
    }

    // MARK: - Manual actions

    /// True while a park started by a trigger is running, so a wake that
    /// lands in the middle of it waits for it instead of finding nothing to
    /// undo.
    private(set) var triggerParkRunning = false

    /// Takes volumes a person just parked or mounted out of the record of
    /// what automatic parks took down, so the next wake leaves them as the
    /// person left them. nil means the whole tower.
    func forgetTriggerParks(onDisks devices: Set<String>?) {
        guard let devices else {
            Preferences.triggerParkedVolumeUUIDs = []
            Preferences.legacyParkedByTrigger = false
            return
        }
        let uuids = disks.filter { devices.contains($0.device) }
            .flatMap(\.allVolumes).compactMap { $0.uuid?.lowercased() }
        forgetTriggerParks(volumes: Set(uuids))
    }

    func forgetTriggerParks(volumes uuids: Set<String>) {
        // The old flag names no volumes, so any action by hand retires it,
        // as it always did.
        Preferences.legacyParkedByTrigger = false
        let current = Preferences.triggerParkedVolumeUUIDs
        let kept = current.subtracting(uuids.map { $0.lowercased() })
        if kept != current { Preferences.triggerParkedVolumeUUIDs = kept }
    }

    private var forceOfferIsLive: Bool {
        guard !lastBlocked.isEmpty, let lastBlockedAt else { return false }
        return Date().timeIntervalSince(lastBlockedAt) < Self.forceOfferLifetime
    }

    /// Expires the offer, and drops any volume a fresh read shows is no longer
    /// mounted: there is nothing left to force on it.
    private func pruneForceOffer() {
        guard !lastBlocked.isEmpty else { return }
        guard forceOfferIsLive else {
            lastBlocked = []
            lastBlockedAt = nil
            return
        }
        guard readFailure == nil else { return }
        let mounted = Set(allVolumes.filter(\.isMounted).compactMap(\.uuid))
        lastBlocked.removeAll { result in
            result.volume.uuid.map { !mounted.contains($0) } ?? false
        }
        if lastBlocked.isEmpty { lastBlockedAt = nil }
    }

    /// Offered only after a manual park failed. The holders are read again
    /// before the prompt, the prompt names what is lost, and only the volumes
    /// it names are forced, found by UUID on a fresh read at that moment
    /// (audit H4).
    func forceUnmountBlocked() {
        guard !busy else { return }
        guard forceOfferIsLive else {
            lastBlocked = []
            lastBlockedAt = nil
            message = "That force offer expired. Park again to see who is holding the drive now."
            return
        }
        let offered = lastBlocked
        // One offer, one answer, whatever the answer turns out to be.
        lastBlocked = []
        lastBlockedAt = nil
        let untracked = offered.filter { $0.volume.uuid == nil }.map(\.volume.displayName)
        guard untracked.isEmpty else {
            message = "\(untracked.joined(separator: ", ")) has no volume UUID, so DrivePark "
                + "cannot be sure it is still the same volume. Nothing was forced."
            return
        }
        let uuids = Set(offered.compactMap(\.volume.uuid))
        // macOS's own words from the failed park. When lsof sees no holder,
        // as with a Time Machine backup in progress, this is the only clue.
        let refusals = Array(Set(offered.compactMap(\.refusal))).sorted()
        busy = true
        message = "Checking who is holding them now…"
        let engine = self.engine
        Task.detached {
            let check = engine.checkForce(volumeUUIDs: uuids)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                switch check {
                case .refused(let reason):
                    self.message = reason
                case .ready(let volumes, let blockers):
                    guard ForcePrompt.confirm(volumes: volumes.map(\.displayName),
                                              blockers: blockers, refusals: refusals) else {
                        self.message = "Left alone. Nothing was forced."
                        return
                    }
                    self.forgetTriggerParks(volumes: Set(volumes.compactMap(\.uuid)))
                    self.runForce(uuids: Set(volumes.compactMap(\.uuid)),
                                  label: volumes.map(\.displayName).joined(separator: ", "))
                }
            }
        }
    }

    var forceOfferLine: String? {
        guard forceOfferIsLive else { return nil }
        let names = lastBlocked.map { $0.volume.displayName }.joined(separator: ", ")
        return "Force unmount \(names)…"
    }

    private func runForce(uuids: Set<String>, label: String) {
        guard !busy else {
            message = "Something else started first. Nothing was forced."
            return
        }
        busy = true
        message = "Forcing…"
        startTicking()
        let engine = self.engine
        Task.detached {
            let outcome = engine.forceUnmount(volumeUUIDs: uuids) { line in
                Task { @MainActor in self.workingOn = line }
            }
            Self.record(outcome, trigger: "force")
            let read = Self.read(after: outcome, engine: engine)
            await MainActor.run { [weak self] in
                self?.finish(outcome, read: read, label: label, trigger: nil,
                             scoped: true, offersForce: false)
            }
        }
    }

    func park(only: Set<String>? = nil, label: String? = nil) {
        // Parked by hand now, so not the next wake's to undo.
        forgetTriggerParks(onDisks: only)
        runPark(only: only, deadline: nil, label: label, completion: nil)
    }

    /// A mount asked for by hand.
    ///
    /// - Returns: false when it declined because something else is running.
    ///   Callers have to know, because a mount that quietly does nothing is
    ///   how the drives stayed parked after a wake on 2026-09-04.
    @discardableResult
    func mount(only: Set<String>? = nil, label: String? = nil) -> Bool {
        guard startMount(subject: label ?? "All volumes", logAs: label == nil ? "manual" : "manual, one drive",
                         work: { $0.mount(onlyDisks: only) }) else { return false }
        forgetTriggerParks(onDisks: only)
        return true
    }

    private func startMount(subject: String, logAs: String,
                            work: @escaping (Engine) -> MountOutcome) -> Bool {
        guard !busy else {
            Preferences.recordDiagnostic(
                "mount", "declined: a park or mount was already running")
            return false
        }
        busy = true
        lastBlocked = []
        lastBlockedAt = nil
        message = "Mounting…"
        let engine = self.engine
        Task.detached {
            let outcome = work(engine)
            Self.record(outcome, trigger: logAs)
            let (mounted, total) = (outcome.mountedCount, outcome.total)
            let split = String(format: " %.1fs.", outcome.timing.total)
            let read = Result { try engine.discover() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(read)
                self.busy = false
                if let failure = outcome.failure {
                    self.message = failure
                } else {
                    self.message = mounted == total
                        ? "\(subject) back online." + split
                        : "\(subject): \(mounted) of \(total) volumes mounted." + split
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
    ///
    /// It mounts only what automatic parks took down and nobody has touched by
    /// hand since, and lifts the veto from only those. It used to mount
    /// everything and drop the whole veto, so a drive parked by hand came back
    /// on the next wake with the rest.
    func mountAfterWake(reason: String) {
        guard !busy else {
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
                self?.mountAfterWake(reason: reason)
            }
            return
        }
        wakeMountAttempts = 0
        let uuids = Preferences.triggerParkedVolumeUUIDs
        let legacy = Preferences.legacyParkedByTrigger
        // Spent whether or not every volume comes back. A wake mount that
        // fails is reported once, not retried on every wake after it.
        Preferences.triggerParkedVolumeUUIDs = []
        Preferences.legacyParkedByTrigger = false
        guard !uuids.isEmpty || legacy else {
            Preferences.recordDiagnostic(
                "wake", "\(reason): nothing left to mount, everything the automatic park took down was parked or mounted by hand since")
            return
        }
        // No message here on purpose. The mount sets one when it finishes and
        // has counted what actually mounted.
        _ = startMount(subject: "Drives parked automatically", logAs: "wake",
                       work: uuids.isEmpty ? { $0.mount(onlyDisks: nil) }
                                           : { $0.mount(volumeUUIDs: uuids) })
        Preferences.recordDiagnostic("wake", uuids.isEmpty
            ? "\(reason): mount started for everything, parked by an earlier build"
            : "\(reason): mount started for \(uuids.count) volume(s) the automatic park took down")
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
        // A request that lands during a park is declined out loud. It used to
        // run on top of the park and then clear the busy flag under it.
        guard !busy else {
            VetoBroker.answerBusy(nonce: request.nonce)
            Preferences.recordDiagnostic(
                "mount", "command line request declined: a park or mount was already running")
            return
        }
        forgetTriggerParks(onDisks: request.disks)
        busy = true
        lastBlocked = []
        lastBlockedAt = nil
        message = "Mounting, asked by the command line…"
        let engine = self.engine
        Task.detached {
            let outcome = engine.mount(onlyDisks: request.disks)
            Self.record(outcome, trigger: "command line")
            let (mounted, total) = (outcome.mountedCount, outcome.total)
            if let failure = outcome.failure {
                VetoBroker.answerFailed(nonce: request.nonce, reason: failure)
            } else {
                VetoBroker.answer(nonce: request.nonce, mounted: mounted, total: total)
            }
            let read = Result { try engine.discover() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(read)
                self.busy = false
                if let failure = outcome.failure {
                    self.message = failure
                } else {
                    self.message = mounted == total
                        ? "All volumes back online, asked by the command line."
                        : "\(mounted) of \(total) volumes mounted."
                }
            }
        }
    }

    private func runPark(only: Set<String>?, deadline: Date?, label: String?,
                         triggerLabel: String? = nil,
                         backup: BackupPolicy = .refuseWhileBackingUp,
                         completion: ((ParkOutcome?) -> Void)?) {
        guard !busy else {
            // Nothing was attempted. Report that, rather than an empty park
            // that would read as success.
            completion?(nil)
            return
        }
        busy = true
        lastBlocked = []
        lastBlockedAt = nil
        message = triggerLabel.map { "Parking because \($0)…" } ?? "Parking…"
        triggerParkRunning = triggerLabel != nil
        startTicking()
        let engine = self.engine
        Task.detached {
            let outcome = engine.park(onlyDisks: only, deadline: deadline, backup: backup) { line in
                Task { @MainActor in self.workingOn = line }
            }
            Self.record(outcome, trigger: triggerLabel ?? (label == nil ? "manual" : "manual, one drive"))
            let read = Self.read(after: outcome, engine: engine)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A park a person asked for, refused because Time Machine is
                // writing to one of the drives: ask them, rather than report
                // a failure they can do nothing about. Nothing was touched.
                if triggerLabel == nil, !outcome.backupInProgress.isEmpty {
                    self.askAboutBackup(outcome, read: read, only: only, label: label)
                    return
                }
                // Trigger-driven parks never leave a force offer behind. A
                // failure you did not watch happen is not a mandate to do
                // something destructive later.
                self.finish(outcome, read: read, label: label, trigger: triggerLabel,
                            scoped: only != nil, offersForce: triggerLabel == nil)
            }
            completion?(outcome)
        }
    }

    private func askAboutBackup(_ outcome: ParkOutcome, read: Result<DiskSnapshot, Error>,
                                only: Set<String>?, label: String?) {
        apply(read)
        busy = false
        stopTicking()
        let names = outcome.backupInProgress.map(\.displayName)
        guard BackupPrompt.confirm(volumes: names) else {
            message = "Not parked. Time Machine is backing up to "
                + names.joined(separator: ", ") + "; park again when it finishes."
            return
        }
        runPark(only: only, deadline: nil, label: label,
                backup: .stopBackupIfRunning, completion: nil)
    }

    /// The read the screen should show after a park: the park's own last
    /// verifying read when it has one. A park that touched the disks and then
    /// could not verify gets no other read in its place, so it can never end
    /// on a checkmark (audit C1); the next refresh reads again.
    nonisolated private static func read(after outcome: ParkOutcome,
                                         engine: Engine) -> Result<DiskSnapshot, Error> {
        if outcome.didWork, let failure = outcome.failure {
            return .failure(DiscoveryFailure(reason: failure))
        }
        if let snapshot = outcome.snapshot { return .success(snapshot) }
        return Result { try engine.discover() }
    }

    private func finish(_ outcome: ParkOutcome, read: Result<DiskSnapshot, Error>,
                        label: String?, trigger: String?, scoped: Bool, offersForce: Bool) {
        apply(read)
        busy = false
        stopTicking()
        message = Self.describe(outcome, label: label, trigger: trigger)
        if offersForce && !outcome.parked {
            lastBlocked = outcome.results.filter { !$0.success }
            lastBlockedAt = lastBlocked.isEmpty ? nil : Date()
        }
        if let trigger {
            // What this automatic park took down is what the next wake may put
            // back. Recorded even when the park as a whole did not verify:
            // whatever it did unmount is still the trigger's doing.
            triggerParkRunning = false
            let tookDown = Set(outcome.results.filter(\.success)
                .compactMap { $0.volume.uuid?.lowercased() })
            if !tookDown.isEmpty {
                Preferences.triggerParkedVolumeUUIDs =
                    Preferences.triggerParkedVolumeUUIDs.union(tookDown)
            }
            Preferences.recordDiagnostic(
                "wakeArm", "park because \(trigger) took down \(tookDown.count) volume(s)")
        }
        notify(outcome, scoped: scoped)
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
        // A whole-second readout does not need the wakeup on the dot.
        tickTimer?.tolerance = 0.25
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
    private func notify(_ outcome: ParkOutcome, scoped: Bool) {
        guard outcome.didWork || !outcome.parked else { return }

        if !outcome.parked {
            let body = outcome.problem ?? "The park did not verify."
            Notifier.shared.post(title: "Park failed", body: body)
            // The card names drives, not the programs holding them (audit,
            // Low): `body` carries pids and paths, and stays on this Mac.
            Transom.post(title: "Park failed, do not undock",
                         message: outcome.cardProblem,
                         symbol: "externaldrive.trianglebadge.exclamationmark",
                         persistent: true,
                         urgent: true)
            Chime.failed.play()
            return
        }

        let parkedNames = outcome.results.filter { $0.success }
            .map { $0.volume.displayName }
        let seconds = String(format: "%.1fs", outcome.timing.total)

        // The same answer the icon gives, from the same read. This used to
        // ask its own question about ignored volumes while the icon asked a
        // narrower one, and they could disagree (audit H1).
        if outcome.safeToPowerOff {
            Notifier.shared.post(
                title: scoped ? "\(parkedNames.joined(separator: ", ")) parked, safe to unplug"
                              : "Tower parked, safe to unplug",
                body: "Nothing on any external disk is mounted. Verified in \(seconds).")
            // Urgent, and it took a real complaint to get here. Wekesa runs
            // Transom filtered to VIPs, codes and urgent, so this card was
            // being held, which is the worst one to hold: it is the only card
            // you ACT on. The failure cards tell you to keep your hands off,
            // and doing nothing is the safe default you would have taken
            // anyway. This is the one that says the waiting is over, and a
            // "safe to undock" that arrives after you have already walked away
            // is the same as no card at all.
            //
            // Still ten seconds rather than persistent. It is not a warning and
            // it should not need dismissing.
            Transom.post(
                title: "Safe to undock",
                message: "\(parkedNames.count) volume(s) verified unmounted in \(seconds), "
                    + "and nothing else is mounted. Pull the cable.",
                symbol: "externaldrive.badge.checkmark",
                duration: 10,
                urgent: true)
            // The one sound that means "pull the cable". Nothing else uses it.
            Chime.safeToUnplug.play()
            return
        }

        let reason = outcome.safetyReason ?? "something is still mounted"
        if scoped {
            let names = parkedNames.joined(separator: ", ")
            Notifier.shared.post(
                title: names.isEmpty ? "Parked" : "\(names) parked",
                body: "Not safe to unplug yet: \(reason).")
            Transom.post(
                title: names.isEmpty ? "Parked" : "\(names) parked",
                message: "Not safe to undock yet: \(outcome.cardSafetyReason).",
                linkTitle: "Drive parked, not safe to undock yet",
                symbol: "externaldrive",
                duration: 10,
                urgent: true)
        } else {
            Notifier.shared.post(
                title: "Tower parked, but not safe to unplug",
                body: "\(reason). Verified in \(seconds).")
            // Persistent on purpose. A tower park that leaves something
            // mounted looks like success and is not, and a card that fades in
            // six seconds is how a mounted drive gets yanked.
            Transom.post(
                title: "Parked, but do NOT undock",
                message: "\(outcome.cardSafetyReason). Verified in \(seconds).",
                symbol: "exclamationmark.triangle.fill",
                persistent: true,
                urgent: true)
        }
        Chime.partial.play()
    }

    /// Writes the timing split and every volume's verdict to the unified log.
    ///
    /// Timings, device nodes, verdicts and attempt counts are public, so
    /// `log show` answers "where did the time go" on any build. Volume names,
    /// the notes (which carry names and disk image paths) and macOS's refusal
    /// text are private outside DEBUG (audit, Low): the unified log is
    /// readable by any admin and travels in every sysdiagnose, and the name of
    /// a drive is often the name of what is on it.
    nonisolated private static func record(_ outcome: ParkOutcome, trigger: String) {
        guard outcome.didWork else {
            parkLog.notice("park (\(trigger, privacy: .public)): nothing to do")
            return
        }
        parkLog.notice("park (\(trigger, privacy: .public)): \(outcome.timing.summary, privacy: .public)")
        for result in outcome.results {
            let verdict = result.success ? "unmounted" : "FAILED"
            let detail = String(format: "%@ in %.2fs, %d attempt(s)", verdict, result.duration, result.attempts)
            logVolume(result.volume, detail)
        }
        for note in outcome.notes { logNote(note) }
    }

    nonisolated private static func record(_ outcome: MountOutcome, trigger: String) {
        guard !outcome.results.isEmpty else {
            parkLog.notice("mount (\(trigger, privacy: .public)): nothing to do")
            return
        }
        parkLog.notice("mount (\(trigger, privacy: .public)): \(outcome.summary, privacy: .public)")
        for result in outcome.results {
            logVolume(result.volume, String(format: "%@ in %.2fs",
                                            result.success ? "mounted" : "FAILED", result.duration))
            if !result.success, let why = result.detail { logNote("  \(result.volume.device): \(why)") }
        }
    }

    /// One volume's line: the name private, the rest public.
    nonisolated private static func logVolume(_ volume: Volume, _ detail: String) {
        #if DEBUG
        parkLog.notice("  \(volume.displayName, privacy: .public) (\(volume.device, privacy: .public)): \(detail, privacy: .public)")
        #else
        parkLog.notice("  \(volume.displayName, privacy: .private) (\(volume.device, privacy: .public)): \(detail, privacy: .public)")
        #endif
    }

    nonisolated private static func logNote(_ note: String) {
        #if DEBUG
        parkLog.notice("  \(note, privacy: .public)")
        #else
        parkLog.notice("  \(note, privacy: .private)")
        #endif
    }

    private static func describe(_ outcome: ParkOutcome, label: String?,
                                 trigger: String?) -> String {
        if let failure = outcome.failure {
            return outcome.didWork ? "Not parked. \(failure)" : failure
        }
        let notSafe = outcome.safetyReason.map { " Not safe to power off: \($0)." } ?? ""
        if outcome.parked && !outcome.didWork {
            return "No action taken. Nothing this run manages was mounted." + notSafe
        }
        if outcome.parked {
            // The split rides along on the menu line so the answer to "why did
            // that take so long" is one click away, not a log query.
            let split = String(format: " %.1fs: unmount %.1f, spin-down %.1f.",
                               outcome.timing.total, outcome.timing.unmount,
                               outcome.timing.spinDown)
            if outcome.safeToPowerOff {
                if let label { return "\(label) parked. Safe to power off." + split }
                if let trigger { return "Parked because \(trigger). Safe to power off." + split }
                return "Parked. Safe to power off the tower." + split
            }
            if let label { return "\(label) parked." + notSafe + split }
            if let trigger { return "Parked because \(trigger)." + notSafe + split }
            return "Parked what DrivePark manages." + notSafe + split
        }
        return "Not parked. " + (outcome.problem ?? "The park did not verify.")
    }

    // MARK: - Settings

    func setTrigger(_ trigger: ParkTrigger, _ on: Bool) {
        Preferences.setEnabled(trigger, on)
        enabledTriggers = Preferences.enabledTriggers
        guard on else {
            triggerWarnings[trigger] = nil
            return
        }
        // Read off the main actor, for the same reason as in refresh().
        Task.detached {
            let status = TriggerHealth.status(for: trigger)
            await MainActor.run { [weak self] in
                guard let self, self.enabledTriggers.contains(trigger) else { return }
                if !status.canFire, let reason = status.reason {
                    // Say it at the moment they switch it on, not only in a
                    // submenu they may never open again.
                    self.message = reason
                    self.triggerWarnings[trigger] = reason
                } else {
                    self.triggerWarnings[trigger] = nil
                }
            }
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
        // Ignored means hands off, and refusing its remount is a hand on it.
        // A parked volume put on the list used to stay vetoed until the app
        // quit, with no Mount offered for it in the menu.
        if on { engine.liftVetoForIgnored() }
        message = on
            ? "\(volume.displayName) is ignored. DrivePark will not unmount it, or stop it mounting."
            : "\(volume.displayName) is managed again."
        objectWillChange.send()
    }

    /// One keystroke, both directions. Park when anything is mounted, mount
    /// when everything is parked. The chimes tell the two apart, which is why
    /// a toggle is safe here: you always hear which way it went.
    func hotKeyPressed() {
        guard !busy, !volumes.isEmpty else { return }
        if nothingToPark {
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
                    guard Preferences.saveTransomToken(found) else {
                        self.message = "The Keychain would not store the token. Nothing was saved."
                        return
                    }
                    Transom.forgetCachedToken()
                    self.turnOnTransomForToken()
                    self.testTransom()
                }
            }
            return
        }
        guard Preferences.saveTransomToken(answer) else {
            message = "The Keychain would not store the token. Nothing was saved."
            return
        }
        Transom.forgetCachedToken()
        guard answer != nil else {
            transomFailure = nil
            message = "Transom token cleared."
            return
        }
        turnOnTransomForToken()
        // Prove it before saying it works. A saved token that 401s is a
        // channel that looks configured and delivers nothing.
        testTransom()
    }

    /// Pasting a token is asking for cards, and they are off by default now.
    private func turnOnTransomForToken() {
        guard !Preferences.transomEnabled else { return }
        Preferences.transomEnabled = true
        transomEnabled = true
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
        ForEach(state.unholdableVolumes, id: \.device) { volume in
            Text("⚠︎ \(volume.displayName) has no volume UUID, so DrivePark cannot keep it unmounted")
        }
        Divider()
        Button(state.busy ? "Working…" : "Park Tower") {
            state.park()
        }

        .disabled(state.busy || state.nothingToPark || state.volumes.isEmpty)
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
