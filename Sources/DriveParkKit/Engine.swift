// Engine.swift: the unmount-verify-park loop, shared by CLI and app.

import Foundation

public struct VolumeParkResult {
    public let volume: Volume
    public let success: Bool
    public let blockers: [String]
    /// What macOS said on the last refusal, word for word. Kept because a
    /// holder lsof cannot see (backupd mid-backup) leaves this as the only
    /// clue, and the force prompt used to show nothing at all in that case.
    public let refusal: String?
    /// Wall-clock time spent on this volume, retry waits included.
    public let duration: TimeInterval
    /// How many solicitations it took. More than one means macOS refused at
    /// least once, which is the interesting case.
    public let attempts: Int
}

/// Where the wall-clock went. Reported rather than estimated, because the
/// whole point of this tool is that it does not guess about its own behaviour.
public struct ParkTiming {
    public var discover: TimeInterval = 0
    /// Reading from every drive at once before the first unmount, so drives
    /// that had spun down wake together rather than one after another.
    public var wake: TimeInterval = 0
    /// Reading hdiutil and detaching any image that pins a managed volume.
    public var diskImages: TimeInterval = 0
    public var unmount: TimeInterval = 0
    /// Both fresh reads: after the unmount, and again after the spin-down.
    public var verify: TimeInterval = 0
    public var spinDown: TimeInterval = 0
    public var total: TimeInterval = 0

    public var summary: String {
        String(format: "%.2fs total (discover %.2f, wake %.2f, images %.2f, unmount %.2f, verify %.2f, spin-down %.2f)",
               total, discover, wake, diskImages, unmount, verify, spinDown)
    }
}

public struct ParkOutcome {
    public let results: [VolumeParkResult]
    /// Managed volumes in this run's scope that the fresh read found mounted.
    public let stillMounted: [Volume]
    /// Volumes seen before the park that the fresh read could not find at all.
    /// Not found is not unmounted: a bay renumbered between the two reads
    /// used to fall out of a `--only` filter and count as parked.
    public let missing: [Volume]
    public let notes: [String]
    public var timing = ParkTiming()
    /// Why this run claims nothing: it touched nothing, or the read after it
    /// failed. Either way there is no verified state to report.
    public let failure: String?
    /// The last fresh read this run stands behind.
    public let snapshot: DiskSnapshot?
    /// What keeps the enclosure from being safe to power off, or nil when it
    /// is safe.
    public let safetyReason: String?
    /// Set when this run touched nothing because Time Machine is backing up
    /// to these volumes. A park a person asked for asks them about it and
    /// runs again with `.stopBackupIfRunning`; an automatic one stops here.
    public let backupInProgress: [Volume]
    /// For a park that did not verify as a whole: the volumes in its scope
    /// that the fresh read shows unmounted, which the veto keeps parked
    /// (decided 2026-10-10). Empty for a verified park, where everything in
    /// scope is held anyway, and for a run with no fresh read to stand on.
    public let keptParked: [Volume]

    init(results: [VolumeParkResult] = [], stillMounted: [Volume] = [], missing: [Volume] = [],
         notes: [String] = [], timing: ParkTiming = ParkTiming(), failure: String? = nil,
         snapshot: DiskSnapshot? = nil, safetyReason: String? = nil,
         backupInProgress: [Volume] = [], keptParked: [Volume] = []) {
        self.backupInProgress = backupInProgress
        self.keptParked = keptParked
        self.results = results
        self.stillMounted = stillMounted
        self.missing = missing
        self.notes = notes
        self.timing = timing
        self.failure = failure
        self.snapshot = snapshot
        self.safetyReason = failure ?? safetyReason
    }

    static func refused(_ reason: String, notes: [String] = []) -> ParkOutcome {
        ParkOutcome(notes: notes, failure: reason)
    }

    /// True when every volume this run was asked to park is verified
    /// unmounted on a fresh read.
    ///
    /// Not the same as "this run parked something": a run that unmounted
    /// nothing, because every volume was ignored or already unmounted, also
    /// satisfies this. Ask `didWork` too. And not the same as safe to power
    /// off: an ignored volume can still be mounted. Ask `safeToPowerOff`.
    public var parked: Bool { failure == nil && stillMounted.isEmpty && missing.isEmpty }

    /// True when this run actually tried to unmount something.
    public var didWork: Bool { !results.isEmpty }

    /// Nothing on any discovered disk is mounted, managed or ignored, and the
    /// kernel reports no mount the read could not account for. The only basis
    /// for the checkmark, the "safe to undock" card and a zero exit from
    /// `park now`.
    public var safeToPowerOff: Bool {
        failure == nil && (snapshot?.verdict.safeToPowerOff ?? false)
    }

    public var blockerSummary: String? {
        let failed = results.filter { !$0.success }
        guard !failed.isEmpty else { return nil }
        return failed.map { result in
            let why = result.blockers.isEmpty
                ? (result.refusal ?? "refused, no reason given")
                : result.blockers.joined(separator: ", ")
            return "\(result.volume.displayName): \(why)"
        }.joined(separator: "; ")
    }

    /// The drives a park that did not verify still keeps parked, as one
    /// sentence, or nil. Names only, so the menu, the banner and the notch
    /// card can all carry it.
    public var keptParkedSentence: String? {
        guard !keptParked.isEmpty else { return nil }
        return "Kept parked: " + keptParked.map(\.displayName).joined(separator: ", ") + "."
    }

    /// Why this is not safe to power off, for a notch card: drive names only.
    public var cardSafetyReason: String {
        snapshot?.verdict.cardReason ?? "something is still mounted"
    }

    /// Why this is not a park, for a notch card. Which drives, never which
    /// programs held them or where anything lives: `problem` names the
    /// blockers and their pids, and that stays in the menu and the CLI.
    public var cardProblem: String {
        if !backupInProgress.isEmpty {
            return "Time Machine is backing up to "
                + backupInProgress.map(\.displayName).joined(separator: ", ") + "."
        }
        if failure != nil {
            return "DrivePark could not verify the park. The menu says why."
        }
        var parts: [String] = []
        if !stillMounted.isEmpty {
            parts.append("Still mounted: " + stillMounted.map(\.displayName).joined(separator: ", ") + ".")
        }
        if !missing.isEmpty {
            parts.append("Not found on the fresh read: " + missing.map(\.displayName).joined(separator: ", ") + ".")
        }
        return parts.isEmpty ? "The park did not verify." : parts.joined(separator: " ")
    }

    /// One line on why this is not a park, or nil when it is.
    public var problem: String? {
        if let failure { return failure }
        var parts: [String] = []
        if !stillMounted.isEmpty {
            parts.append("Still mounted: " + stillMounted.map(\.displayName).joined(separator: ", ") + ".")
        }
        if !missing.isEmpty {
            parts.append("Not found on the fresh read: "
                         + missing.map(\.displayName).joined(separator: ", ") + ".")
        }
        if let blockers = blockerSummary { parts.append("Blocked by \(blockers).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public struct VolumeMountResult {
    public let volume: Volume
    public let success: Bool
    public let detail: String?
    /// Wall-clock time for this volume's mount request. When the drive was
    /// spun down this is mostly the platters coming back up.
    public let duration: TimeInterval
}

public struct MountOutcome {
    /// One entry per volume this run asked to mount, in discovery order.
    public let results: [VolumeMountResult]
    /// Managed volumes in scope, and how many the verifying read found mounted.
    public let total: Int
    public let mountedCount: Int
    public var timing = MountTiming()
    /// Set when nothing was mounted, or when the read afterwards failed.
    public var failure: String?

    public var summary: String { timing.summary }
}

/// Where a mount's wall-clock went. Same discipline as ParkTiming: measured,
/// never estimated.
public struct MountTiming {
    public var discover: TimeInterval = 0
    public var mount: TimeInterval = 0
    public var verify: TimeInterval = 0
    public var total: TimeInterval = 0

    public var summary: String {
        String(format: "%.2fs total (discover %.2f, mount %.2f, verify %.2f)",
               total, discover, mount, verify)
    }
}

/// What a force would touch, read fresh before the prompt is shown.
public enum ForceCheck {
    /// Still mounted, and who is holding them right now.
    case ready(volumes: [Volume], blockers: [String])
    /// Nothing will be forced, and why.
    case refused(String)
}

public final class Engine {
    private let discovery: DiskDiscovering
    private let ops: DiskOperating?
    private let backups: BackupReading
    private let isIgnored: (String?) -> Bool
    private let ladder: [TimeInterval]
    public static let retryDelays: [TimeInterval] = [0, 2, 5, 10]

    /// The real disks, through Disk Arbitration and diskutil.
    public convenience init() {
        let ops = DiskOps()
        // The veto is registered once and gated by vetoedVolumeUUIDs: empty
        // set = inert, populated = active hold.
        ops?.startMountVeto()
        self.init(discovery: SystemDiscovery(), ops: ops)
    }

    /// - Parameter isIgnored: the ignore list. Injected so a test never reads
    ///   or writes the preferences of the Mac it runs on.
    /// - Parameter backups: Time Machine. Injected so a test never runs tmutil.
    public init(discovery: DiskDiscovering, ops: DiskOperating?,
                backups: BackupReading = SystemBackups(),
                isIgnored: @escaping (String?) -> Bool = Preferences.isIgnored,
                retryDelays: [TimeInterval] = Engine.retryDelays) {
        self.discovery = discovery
        self.ops = ops
        self.backups = backups
        self.isIgnored = isIgnored
        self.ladder = retryDelays
    }

    /// A fresh read. Throws rather than answering with an empty list.
    public func discover() throws -> DiskSnapshot {
        try discovery.discover()
    }

    public var isVetoActive: Bool { !(ops?.vetoedVolumeUUIDs.isEmpty ?? true) }

    public var vetoedVolumeUUIDs: Set<String> { ops?.vetoedVolumeUUIDs ?? [] }

    /// Lifts the veto from every volume now on the ignore list.
    ///
    /// Ignoring a parked volume used to leave it vetoed until the app quit:
    /// Finder said "Parked by DrivePark" and the menu, which hides ignored
    /// drives, offered no way to mount it. Ignored means DrivePark keeps its
    /// hands off, and refusing a mount is a hand on it.
    public func liftVetoForIgnored() {
        guard let ops else { return }
        let current = ops.vetoedVolumeUUIDs
        let kept = current.filter { !isIgnored($0) }
        if kept != current { ops.vetoedVolumeUUIDs = kept }
    }

    enum Scope {
        case everything
        case disks(Set<String>)
        /// Lowercased volume UUIDs.
        case volumes(Set<String>)
        /// Every disk that holds one of these volume UUIDs on the fresh read.
        /// A drive named the way the menu sees it, found the way it is now.
        case disksHolding(Set<String>)
    }

    /// Resolves a drive named by its volumes to the disks it is on right now.
    private static func resolve(_ scope: Scope, in snapshot: DiskSnapshot) -> Scope? {
        guard case .disksHolding(let uuids) = scope else { return scope }
        let names = snapshot.disks
            .filter { $0.allVolumes.contains { $0.uuid.map(uuids.contains) ?? false } }
            .map(\.device)
        return names.isEmpty ? nil : .disks(Set(names))
    }

    /// Parks the drive that holds these volumes, found on a fresh read.
    ///
    /// For the menu's per-drive buttons. They used to pass the disk's BSD name
    /// from the last refresh, up to 30 s old, and a bay renumbered in that
    /// time would have been a different drive by the time it was parked.
    public func park(drivesHolding volumeUUIDs: Set<String>,
                     backup: BackupPolicy = .refuseWhileBackingUp,
                     progress: (String) -> Void = { _ in }) -> ParkOutcome {
        run(scope: .disksHolding(Set(volumeUUIDs.map { $0.lowercased() })),
            deadline: nil, force: false, backup: backup, progress: progress)
    }

    /// Mounts the drive that holds these volumes, found on a fresh read.
    public func mount(drivesHolding volumeUUIDs: Set<String>,
                      progress: (String) -> Void = { _ in }) -> MountOutcome {
        runMount(scope: .disksHolding(Set(volumeUUIDs.map { $0.lowercased() })), progress: progress)
    }

    /// - Parameter deadline: when set, the retry ladder stops once passed. The
    ///   sleep path needs this: macOS gives roughly 30 s between
    ///   kIOMessageSystemWillSleep and a forced sleep, and the full ladder can
    ///   outlast it. A park cut short by the deadline reports what it reached,
    ///   it does not claim more.
    /// - Parameter force: tears the filesystem down even with files open.
    ///   Unwritten data in those files is lost. Never defaulted, never
    ///   persisted, and never reachable from a trigger: a screen lock that
    ///   force-unmounts a drive mid-write would be the worst thing this app
    ///   could do. It exists as a one-shot remedy a human asks for by name,
    ///   after a normal park has already failed and named the blocker.
    /// - Parameter backup: what to do about a Time Machine backup running
    ///   onto a volume this park would unmount. Refused unless a person was
    ///   asked and said yes.
    public func park(onlyDisks: Set<String>? = nil,
                     deadline: Date? = nil,
                     force: Bool = false,
                     backup: BackupPolicy = .refuseWhileBackingUp,
                     progress: (String) -> Void = { _ in }) -> ParkOutcome {
        run(scope: onlyDisks.map(Scope.disks) ?? .everything,
            deadline: deadline, force: force, backup: backup, progress: progress)
    }

    /// Who is holding these volumes right now, read fresh, for the force
    /// prompt. The list a failed park left behind is minutes old by the time
    /// anyone clicks Force, and the holder it named may be long gone or
    /// replaced.
    public func checkForce(volumeUUIDs: Set<String>) -> ForceCheck {
        guard let ops else { return .refused("Disk Arbitration is unavailable. Nothing was forced.") }
        let wanted = Set(volumeUUIDs.map { $0.lowercased() })
        let snapshot: DiskSnapshot
        do { snapshot = try discovery.discover() } catch {
            return .refused("Could not read the disks, so nothing was forced: \(error)")
        }
        let found = snapshot.disks.flatMap(\.allVolumes).filter { $0.uuid.map(wanted.contains) ?? false }
        guard Set(found.compactMap(\.uuid)) == wanted else {
            return .refused("A volume from the failed park is no longer attached. Nothing was forced.")
        }
        let mounted = found.filter { $0.isMounted && !isIgnored($0.uuid) }
        guard !mounted.isEmpty else {
            return .refused("Nothing to force: " + found.map(\.displayName).joined(separator: ", ")
                            + " is no longer mounted.")
        }
        let images = discovery.attachedImages() ?? []
        var blockers: Set<String> = []
        // lsof cannot see backupd writing, and it is the holder a person most
        // needs to hear about before forcing.
        if case .backingUp(let busy) = backupCheck(toUnmount: mounted, status: backups.backupStatus(),
                                                   isDestination: backups.isBackupDestination) {
            for volume in busy { blockers.insert("Time Machine (a backup to \(volume.displayName) is running)") }
        }
        for volume in mounted {
            guard let mountPoint = volume.mountPoint else { continue }
            blockers.formUnion(ops.blockers(mountPoint: mountPoint))
            for image in imagesBacked(byVolumeAt: resolvedPath(mountPoint), in: images) {
                blockers.insert("the disk image \(image.displayPath)")
            }
        }
        return .ready(volumes: mounted, blockers: blockers.sorted())
    }

    /// Force-unmounts exactly the volumes a person confirmed, and nothing else.
    ///
    /// Audit H4. Force used to act on the blocked list a failed park left
    /// behind, which never expired: it took the old BSD names, widened them to
    /// every mounted volume on those disks plus any disk image stored there,
    /// and when a timed-out refresh had left the disk list empty it widened to
    /// the whole tower. Now the UUIDs are mapped to devices on a fresh read at
    /// the moment of confirming, and if any one of them cannot be mapped,
    /// nothing is forced.
    public func forceUnmount(volumeUUIDs: Set<String>,
                             progress: (String) -> Void = { _ in }) -> ParkOutcome {
        guard !volumeUUIDs.isEmpty else { return .refused("No volume was named. Nothing was forced.") }
        // The force prompt named any backup in progress, so the person who
        // confirmed it has already been asked.
        return run(scope: .volumes(Set(volumeUUIDs.map { $0.lowercased() })),
                   deadline: nil, force: true, backup: .stopBackupIfRunning, progress: progress)
    }

    /// The key a volume is tracked by across reads: its UUID, or its device
    /// when it has none.
    private static func key(_ volume: Volume) -> String {
        volume.uuid ?? "device:\(volume.device)"
    }

    private func run(scope: Scope, deadline: Date?, force: Bool, backup: BackupPolicy,
                     progress: (String) -> Void) -> ParkOutcome {
        guard let ops else {
            return .refused("Disk Arbitration session unavailable. Nothing was touched.")
        }
        let started = Date()
        var timing = ParkTiming()
        let before: DiskSnapshot
        do { before = try discovery.discover() } catch {
            return .refused("Could not read the disks before parking, so nothing was touched: \(error)")
        }
        timing.discover = Date().timeIntervalSince(started)
        guard let scope = Self.resolve(scope, in: before) else {
            return .refused("That drive is not on a fresh read; it may have been unplugged. Nothing was touched.")
        }

        let disks: [PhysicalDisk]
        let inScope: (Volume) -> Bool
        switch scope {
        case .disksHolding:
            return .refused("That drive could not be found. Nothing was touched.")
        case .everything:
            disks = before.disks
            inScope = { _ in true }
        case .disks(let names):
            disks = before.disks.filter { names.contains($0.device) }
            let unknown = names.subtracting(disks.map(\.device))
            guard unknown.isEmpty else {
                return .refused("No external disk named \(unknown.sorted().joined(separator: ", ")). Nothing was touched.")
            }
            inScope = { _ in true }
        case .volumes(let uuids):
            let named = before.disks.flatMap(\.allVolumes).filter { $0.uuid.map(uuids.contains) ?? false }
            guard Set(named.compactMap(\.uuid)) == uuids else {
                return .refused("A volume named for force is not on a fresh read. Nothing was forced.")
            }
            disks = before.disks.filter { $0.allVolumes.contains { $0.uuid.map(uuids.contains) ?? false } }
            inScope = { $0.uuid.map(uuids.contains) ?? false }
        }

        // The ignore list is absolute. Not overridden by naming the drive, not
        // overridden by Park Tower. A volume you told DrivePark to leave alone
        // is one it must not unmount while something is mid-copy on it, and an
        // override that one click can reach is not a guarantee.
        var notes: [String] = []
        var targets: [Volume] = []
        for volume in disks.flatMap(\.allVolumes) where inScope(volume) {
            if isIgnored(volume.uuid) {
                notes.append("\(volume.displayName): left alone, on the ignore list")
            } else {
                targets.append(volume)
            }
        }
        // Discovery already leaves the running system out. This is the second
        // lock on the same door: nothing mounted at / or under
        // /System/Volumes is ever unmounted, whatever a read says.
        let systemVolumes = targets.filter { isProtectedMountPoint($0.mountPoint) }
        for volume in systemVolumes {
            notes.append("\(volume.displayName): refused, mounted at \(volume.displayMountPoint ?? "?"), which belongs to the running system")
        }
        let toUnmount = targets.filter { $0.isMounted && !isProtectedMountPoint($0.mountPoint) }
        guard !toUnmount.isEmpty else {
            if systemVolumes.isEmpty {
                notes.append("Nothing to park: no managed volume was mounted. Veto left as it was.")
            }
            timing.total = Date().timeIntervalSince(started)
            return ParkOutcome(stillMounted: systemVolumes, notes: notes, timing: timing,
                               snapshot: before,
                               safetyReason: before.verdict.reason(isIgnored: isIgnored))
        }

        // Asked before anything is touched, the veto included.
        let backupStatus = backups.backupStatus()
        // Parking a destination stops backups to it, which should be said.
        for volume in timeMachineDestinations(in: toUnmount, status: backupStatus,
                                              isDestination: backups.isBackupDestination) {
            notes.append("\(volume.displayName): Time Machine backs up here. Backups to it stop "
                         + "while it is parked and resume when it is mounted.")
        }
        // A backup this park was told to stop holds the volume through
        // backupd, which runs as root, so lsof cannot name it.
        var timeMachineHolders: [String: [String]] = [:]
        switch backupCheck(toUnmount: toUnmount, status: backupStatus,
                           isDestination: backups.isBackupDestination) {
        case .clear(let note):
            if let note { notes.append(note) }
        case .backingUp(let busy):
            let names = busy.map(\.displayName).joined(separator: ", ")
            guard case .stopBackupIfRunning = backup else {
                timing.total = Date().timeIntervalSince(started)
                return ParkOutcome(notes: notes, timing: timing,
                                   failure: "Time Machine is backing up to \(names). Parking would stop "
                                       + "the backup, so nothing was parked.",
                                   backupInProgress: busy)
            }
            notes.append("Time Machine was backing up to \(names). Parked anyway, as asked; "
                         + "that backup stops and picks up again on the next one.")
            for volume in busy {
                timeMachineHolders[volume.device] = ["Time Machine (a backup to this volume is running)"]
            }
        }

        // The veto goes up before the first unmount, not after the last
        // (audit H5). The courtesy spin-down can make an enclosure
        // re-enumerate and macOS automount what was just unmounted, and a veto
        // armed after that is too late to refuse it. If the park does not
        // verify, the veto ends up holding what the fresh read shows parked
        // and nothing else (vetoAfterIncompletePark). Union, so per-drive
        // parks accumulate.
        let vetoBefore = ops.vetoedVolumeUUIDs
        let armed = vetoBefore.union(targets.filter { !isProtectedMountPoint($0.mountPoint) }
            .compactMap { $0.uuid?.lowercased() })
        if armed != vetoBefore { ops.vetoedVolumeUUIDs = armed }
        // The veto matches on volume UUID, so a volume without one is parked
        // but not held: anything can mount it again. Said here, every park,
        // rather than left for someone to find out (audit, Low).
        for volume in toUnmount where volume.uuid == nil {
            notes.append("\(volume.displayName) has no volume UUID, so DrivePark cannot keep it "
                         + "unmounted: macOS or another app can mount it again.")
        }

        // WAKE (2026-10-10). The drives go idle within about a minute, and a
        // park on idle drives waited for them one at a time: 25.03 s at
        // worst, past the 20 s a sleep park gets. One read per drive, all at
        // once, so the spin-ups overlap; then the unmounts find every drive
        // awake. Only drives this run is about to unmount: never one that
        // carries only ignored or already unmounted volumes. A read that does
        // not come back in time is said and not waited on further.
        let wakeStarted = Date()
        let toWake = Self.wakeTargets(toUnmount: toUnmount, disks: disks)
        if !toWake.isEmpty {
            let budget = Self.wakeBudget(deadline: deadline)
            if budget < 1 {
                notes.append("Did not wake the drives first: out of time before sleep.")
            } else {
                progress("Waking \(toWake.map(\.displayName).joined(separator: ", "))")
                let wakeLock = NSLock()
                var answers = [WakeResult](repeating: .timedOut, count: toWake.count)
                DispatchQueue.concurrentPerform(iterations: toWake.count) { index in
                    let answer = ops.wake(mountPoint: toWake[index].mountPoint ?? "", timeout: budget)
                    wakeLock.lock(); answers[index] = answer; wakeLock.unlock()
                }
                notes.append(contentsOf: Self.wakeNotes(toWake, answers, budget: budget))
            }
        }
        timing.wake = Date().timeIntervalSince(wakeStarted)

        // A disk image backed by a file on one of these volumes pins it.
        // Resolved here, before the unmount loop, and never as a rung on the
        // retry ladder: measured on the tower 2026-09-09, the dissent lands in
        // 0.28s and never clears, so the ladder would spend its full 17s
        // learning what one hdiutil call already knows. `lsof -Fpc` can only
        // answer "diskimages-helper (pid 29138)", which nobody can act on;
        // the backing path is the sentence that means something.
        //
        // Not gated on Preferences.includeDiskImages. That setting decides
        // whether a .dmg is a parkable drive. This decides whether one is in
        // the way, which is a different question, and gating them together
        // would make an off-by-default setting a way to make parks fail.
        let imagesStarted = Date()
        // Volumes the unmount loop must not attempt: either their pinning
        // image would not let go, or they belong to an image that is now
        // detached and whose device no longer exists.
        var skipVolumes: Set<String> = []
        // Keys of volumes a detach or a spin-down removed on purpose, which
        // the verify must not report as missing.
        var mayVanish: Set<String> = []
        let attachedImages = discovery.attachedImages()
        if let attachedImages, !attachedImages.isEmpty {
            for volume in toUnmount {
                guard let mountPoint = volume.mountPoint else { continue }
                for image in imagesBacked(byVolumeAt: resolvedPath(mountPoint), in: attachedImages) {
                    progress("Detaching disk image \(image.displayPath)")
                    // The image's own volumes come down first. DADiskEject on
                    // the whole disk with them still mounted answers busy;
                    // `diskutil eject` only looks like one step because it does
                    // this first. Force inherits here, under the same contract
                    // as everywhere else: one-shot, asked for by name, never
                    // reachable from a trigger.
                    var refusal: String?
                    for entity in image.mountedVolumes {
                        let result = ops.unmount(volumeBSDName: entity, force: force)
                        if !result.success {
                            refusal = result.detail ?? "unknown"
                            break
                        }
                    }
                    if refusal == nil {
                        let result = ops.eject(diskBSDName: image.wholeDisk)
                        if !result.success { refusal = result.detail ?? "unknown" }
                    }
                    if let refusal {
                        skipVolumes.insert(volume.device)
                        // Name what is open inside the image. "Preview (pid
                        // 900)" is something a human can act on; "DA status
                        // 0xc010" is not.
                        let inside = image.mountPoints.flatMap { ops.blockers(mountPoint: $0) }
                        let held = inside.isEmpty ? refusal : inside.joined(separator: ", ")
                        notes.append("\(image.displayPath): still attached, held by \(held). It is backed by a file on \(volume.displayName), so that volume cannot unmount until the image lets go.")
                    } else {
                        skipVolumes.formUnion(image.mountedVolumes)
                        for gone in before.disks.flatMap(\.allVolumes)
                        where image.mountedVolumes.contains(gone.device) {
                            mayVanish.insert(Self.key(gone))
                        }
                        if let imageDisk = before.disks.first(where: { $0.device == image.wholeDisk }) {
                            mayVanish.formUnion(imageDisk.allVolumes.map(Self.key))
                        }
                        notes.append("\(image.displayPath): disk image detached, it was backed by a file on \(volume.displayName)")
                    }
                }
            }
        } else if attachedImages == nil {
            notes.append("Could not read attached disk images: hdiutil did not answer. An image backed by one of these drives would dissent its unmount without being named.")
        }
        timing.diskImages = Date().timeIntervalSince(imagesStarted)

        // Force does not climb the retry ladder. The ladder exists to wait a
        // blocker out; force refuses to wait, so retrying it is just repeating
        // the same violence.
        let ladder = force ? [TimeInterval(0)] : self.ladder

        // One disk at a time, and each one waited on the same stranger.
        // Measured on the tower 2026-09-08: a full park took 23 s, and
        // discovery for all three bays is about a second of that. The rest
        // was three unmounts of roughly 11 s each, paid in sequence.
        //
        // The 11 s was not the filesystem. diskarbitrationd offers every
        // unmount to each client holding an unmount-approval callback, waits
        // about 10.6 s for one that never answers, logs "not responding" and
        // only then unmounts, which takes 0.2 to 0.6 s. Ejectify was that
        // client. With it running, the same park measured 12.16 s here; with
        // it quit, 1.93 s. DrivePark cannot shorten another process's
        // approval timeout, so this loop does the one thing it can: it runs
        // the disks concurrently, so the wait is paid once instead of three
        // times. Within a disk the volumes stay sequential; two flushes
        // contending for one spindle would only slow each other.
        //
        // 2026-10-02, Ejectify long gone, the same ~10.6 s timeout was back,
        // and only when Bottom Drawer or Plex was in the park. Spotlight
        // indexing was on for those two and off for Backup. Every
        // mdworker_shared that Spotlight launches registers an unmount and an
        // eject approval callback (16 of 16 registrations in one minute landed
        // 30 to 60 ms after an mdworker spawn), and a worker busy importing
        // does not answer. The stalled approval holds every queued unmount,
        // so one indexed volume slowed the whole park. DrivePark cannot answer
        // for another process. Excluding the two volumes in Spotlight's Search
        // Privacy fixed it: four tower parks through the app at 2.65 to
        // 3.00 s, no "not responding" (SPEC section 10, 2026-10-02).
        //
        // Spin-down stays sequential, and only touches disks this run
        // unmounted (see spinDownDecision). The TerraMaster bridge that
        // stopped answering every bay at once on 2026-08-31 is not a thing
        // to send three STOP UNIT commands to at once.
        let unmountStarted = Date()
        let relocate = Self.relocator(discovery)
        let attempt = Set(toUnmount.map(\.device)).subtracting(skipVolumes)
        let lock = NSLock()
        var indexedResults: [(disk: Int, volume: Int, result: VolumeParkResult)] = []
        // The progress closure is not written for reentry: the app hops it to
        // the main actor, the CLI prints. Serialized, so neither has to be.
        // withoutActuallyEscaping because concurrentPerform returns only when
        // every iteration has, so nothing here outlives the call.
        withoutActuallyEscaping(progress) { progress in
            let report: (String) -> Void = { line in
                lock.lock(); defer { lock.unlock() }
                progress(line)
            }
            DispatchQueue.concurrentPerform(iterations: disks.count) { diskIndex in
                let disk = disks[diskIndex]
                for (volumeIndex, volume) in disk.allVolumes.enumerated()
                where attempt.contains(volume.device) {
                    let result = Self.unmountWithRetries(
                        volume, ops: ops, ladder: ladder, deadline: deadline,
                        force: force, knownHolders: timeMachineHolders[volume.device] ?? [],
                        relocate: relocate, progress: report)
                    lock.lock()
                    indexedResults.append((diskIndex, volumeIndex, result))
                    lock.unlock()
                }
            }
        }
        // Report in discovery order, whatever order the threads finished in.
        let results = indexedResults
            .sorted { ($0.disk, $0.volume) < ($1.disk, $1.volume) }
            .map { $0.result }
        // The disks this run actually took a volume off. Only these get the
        // courtesy spin-down; see spinDownDecision for why.
        let unmountedThisRun = Set(indexedResults
            .filter { $0.result.success }
            .map { disks[$0.disk].device })
        timing.unmount = Date().timeIntervalSince(unmountStarted)

        // VERIFY with a fresh read. Never trust the callbacks alone, and never
        // read a failed read as an empty one (audit C1).
        let verifyStarted = Date()
        var check = verify(targets, scope: scope, mayVanish: mayVanish,
                           stage: "the park")
        timing.verify = Date().timeIntervalSince(verifyStarted)

        // The courtesy spin-down, only after a verified park. A run that did
        // not park leaves the drives spinning: nobody is about to unplug
        // them, and an eject that makes the bridge re-enumerate is one more
        // chance for macOS to bring a volume back with no veto standing.
        let spinStarted = Date()
        if check.ok, let after = check.snapshot {
            var sent = false
            if let deadline, Date() >= deadline {
                notes.append("Spin-down skipped: out of time before sleep.")
            } else {
                for disk in after.disks {
                    switch Self.spinDownDecision(for: disk, unmountedThisRun: unmountedThisRun,
                                                 isIgnored: isIgnored) {
                    case .notThisRun, .stillMounted:
                        continue
                    case .leftSpinningForIgnored:
                        notes.append("\(disk.device): left spinning, it carries an ignored volume that is still mounted")
                        continue
                    case .send:
                        break
                    }
                    sent = true
                    let result = ops.eject(diskBSDName: disk.device)
                    let attached = ops.isAttached(diskBSDName: disk.device)
                    if result.success && attached {
                        notes.append("\(disk.device): spin-down sent; still attached (fixed media, expected)")
                    } else if result.success {
                        notes.append("\(disk.device): ejected and detached")
                        mayVanish.formUnion(disk.allVolumes.map(Self.key))
                    } else {
                        notes.append("\(disk.device): spin-down refused: \(result.detail ?? "unknown")")
                    }
                }
            }
            timing.spinDown = Date().timeIntervalSince(spinStarted)
            // And read again (audit H5). The first read said parked before the
            // eject; what matters is whether it is still true after it.
            if sent {
                let again = Date()
                check = verify(targets, scope: scope, mayVanish: mayVanish,
                               stage: "the spin-down")
                timing.verify += Date().timeIntervalSince(again)
                for volume in check.stillMounted {
                    notes.append("\(volume.displayName): mounted again after the spin-down")
                }
            }
        }

        var keptParked: [Volume] = []
        if !check.ok {
            let after = Self.vetoAfterIncompletePark(before: vetoBefore, targets: targets,
                                                     check: check)
            if ops.vetoedVolumeUUIDs != after.veto { ops.vetoedVolumeUUIDs = after.veto }
            keptParked = after.kept
            if after.kept.isEmpty {
                notes.append("Remount veto put back as it was before this run: the park did not verify.")
            } else {
                let kept = after.kept.map(\.displayName).joined(separator: ", ")
                let dropped = after.dropped.map(\.displayName).joined(separator: ", ")
                notes.append("Remount veto kept on \(kept), verified unmounted"
                             + (dropped.isEmpty ? "." : ", and dropped from \(dropped), which did not park."))
            }
        }
        // A volume this run was responsible for and cannot find makes the
        // whole run unverified, not just unparked. Otherwise the read could
        // say nothing is mounted, the checkmark would follow it, and the same
        // run would be reporting a failure.
        var failure = check.failure
        if failure == nil, !check.missing.isEmpty {
            let names = check.missing.map(\.displayName).joined(separator: ", ")
            failure = "Could not verify: \(names) was seen before the park and is not on the fresh read. Not found is not unmounted."
        }
        timing.total = Date().timeIntervalSince(started)
        return ParkOutcome(results: results, stillMounted: check.stillMounted,
                           missing: check.missing, notes: notes, timing: timing,
                           failure: failure, snapshot: check.snapshot,
                           safetyReason: check.snapshot?.verdict.reason(isIgnored: isIgnored),
                           keptParked: keptParked)
    }

    /// The longest a wake waits, with no sleep coming. Backup, the slowest
    /// bay, spins up in about 12.3 s (measured 2026-09-08).
    static let wakeTimeout: TimeInterval = 15

    /// How long the wake may take. Before sleep it leaves 6 s of the
    /// deadline for the unmounts, the read after them and the report; under
    /// a second is not worth starting.
    static func wakeBudget(deadline: Date?, now: Date = Date()) -> TimeInterval {
        guard let deadline else { return wakeTimeout }
        return min(wakeTimeout, deadline.timeIntervalSince(now) - 6)
    }

    /// One mounted volume per disk this run is about to unmount from: reading
    /// one volume wakes the whole drive. In discovery order.
    static func wakeTargets(toUnmount: [Volume], disks: [PhysicalDisk]) -> [Volume] {
        let going = Set(toUnmount.map(\.device))
        return disks.compactMap { disk in
            disk.allVolumes.first { going.contains($0.device) && $0.mountPoint != nil }
        }
    }

    /// What the wake is worth saying. A drive that was already awake answers
    /// in hundredths of a second and is not mentioned; one that took a second
    /// or more had spun down, and the time it took is the time this park
    /// would otherwise have spent waiting on it, likely more than once.
    static func wakeNotes(_ volumes: [Volume], _ answers: [WakeResult],
                          budget: TimeInterval) -> [String] {
        var slow: [String] = []
        var notes: [String] = []
        for (volume, answer) in zip(volumes, answers) {
            switch answer {
            case .woke(let seconds) where seconds >= 1:
                slow.append(String(format: "%@ %.1f s", volume.displayName, seconds))
            case .timedOut:
                notes.append(String(format: "%@ did not answer a read within %.0f s; parking it anyway.",
                                    volume.displayName, budget))
            default:
                break
            }
        }
        if !slow.isEmpty {
            notes.insert("Woke the drives first, all at once: " + slow.joined(separator: ", ") + ".", at: 0)
        }
        return notes
    }

    /// What the veto holds after a park that did not verify as a whole.
    ///
    /// Decided 2026-10-10, after a partial park on the tower: Backup held
    /// busy, the other three unmounted, and the veto was then put back as it
    /// was before the run, so a plain `diskutil mount` brought Plex straight
    /// back 23 s later. Someone who pressed Park asked for every one of
    /// those drives to be parked. The one that refused stays mounted and
    /// unvetoed; the ones that went down stay down.
    ///
    /// The veto follows the fresh read and nothing else. Kept: every volume
    /// in scope that the read shows unmounted, or that this run removed on
    /// purpose (a detached disk image). Dropped: anything the read shows
    /// still mounted, and anything it cannot find, because not found is not
    /// unmounted. No read at all keeps nothing new and puts the veto back as
    /// it was (audit C1): a run that cannot verify claims nothing, a hold
    /// included.
    static func vetoAfterIncompletePark(before: Set<String>, targets: [Volume],
                                        check: Verification)
        -> (veto: Set<String>, kept: [Volume], dropped: [Volume]) {
        guard check.snapshot != nil else { return (before, [], []) }
        let notParked = Set((check.stillMounted + check.missing).compactMap { $0.uuid?.lowercased() })
        let holdable = targets.filter { $0.uuid != nil && !isProtectedMountPoint($0.mountPoint) }
        let kept = holdable.filter { !notParked.contains($0.uuid!.lowercased()) }
        let dropped = holdable.filter {
            let uuid = $0.uuid!.lowercased()
            return notParked.contains(uuid) && !before.contains(uuid)
        }
        return (before.union(kept.map { $0.uuid!.lowercased() }), kept, dropped)
    }

    struct Verification {
        var snapshot: DiskSnapshot?
        var failure: String?
        var stillMounted: [Volume] = []
        var missing: [Volume] = []
        var ok: Bool { failure == nil && stillMounted.isEmpty && missing.isEmpty }
    }

    private func verify(_ expected: [Volume], scope: Scope, mayVanish: Set<String>,
                        stage: String) -> Verification {
        do {
            let snapshot = try discovery.discover()
            return Self.compare(expected, against: snapshot, scope: scope,
                                mayVanish: mayVanish, isIgnored: isIgnored)
        } catch {
            return Verification(failure: "Could not verify \(stage): \(error). Nothing is claimed as parked.")
        }
    }

    /// Every volume this run was responsible for, looked up on a fresh read
    /// by UUID rather than by disk name. A bay renumbered between the two
    /// reads is still the same volume; one that cannot be found is reported
    /// missing, never counted as unmounted.
    static func compare(_ expected: [Volume], against snapshot: DiskSnapshot, scope: Scope,
                        mayVanish: Set<String>,
                        isIgnored: (String?) -> Bool) -> Verification {
        var result = Verification(snapshot: snapshot)
        let after = snapshot.disks.flatMap(\.allVolumes)
        var homeDisks: Set<String> = []
        for volume in expected {
            let now: Volume?
            if let uuid = volume.uuid {
                now = after.first { $0.uuid == uuid }
            } else {
                now = after.first { $0.uuid == nil && $0.device == volume.device }
            }
            guard let now else {
                if !mayVanish.contains(key(volume)) { result.missing.append(volume) }
                continue
            }
            if now.isMounted { result.stillMounted.append(now) }
            if let home = snapshot.disks.first(where: { $0.allVolumes.contains(now) }) {
                homeDisks.insert(home.device)
            }
        }
        // Managed volumes this run did not know about, mounted since it began:
        // anywhere for a tower park, on the same disks for a drive park, and
        // nowhere for a force, which touches only what was confirmed.
        let neighbours: [Volume]
        switch scope {
        case .everything: neighbours = after
        case .disks, .disksHolding:
            neighbours = snapshot.disks.filter { homeDisks.contains($0.device) }.flatMap(\.allVolumes)
        case .volumes: neighbours = []
        }
        let counted = Set(result.stillMounted.map(\.device))
        for volume in neighbours
        where volume.isMounted && !isIgnored(volume.uuid) && !counted.contains(volume.device) {
            result.stillMounted.append(volume)
        }
        return result
    }

    enum SpinDownDecision: Equatable {
        /// Send the courtesy eject.
        case send
        /// Not unmounted by this run: parked earlier, or never mounted.
        case notThisRun
        /// Something this run manages is still mounted on it; the park failed
        /// there and the report already says so.
        case stillMounted
        /// An ignored volume is still mounted on it.
        case leftSpinningForIgnored
    }

    /// Whether a disk gets the courtesy spin-down after a park.
    ///
    /// Only a disk this run took a volume off. Measured on the tower
    /// 2026-10-02: the eject was going to every disk in the tower with nothing
    /// mounted, including bays parked by an earlier run and long since asleep
    /// under disksleep. DADiskEject on a sleeping drive spins it up first, so
    /// a tower park with Backup mounted and the other two already parked spent
    /// 18.4 to 18.6 s in spin-down (Bottom Drawer 8.2, Plex 10.2, in sequence)
    /// against 0.3 s of unmount. Three runs, same numbers. A disk this run
    /// just unmounted is awake by definition, so its eject costs ~1 ms.
    ///
    /// Limited this way, the spin-down also started working. Under the old
    /// rule Backup remounted in 0.87 s about 90 s after its spin-down, twice,
    /// because the ejects that woke the other two bays came after it. With
    /// only the bays this run unmounted getting the eject, all three stay
    /// down: the next mount pays full spin-up (Backup 12.4 s, Bottom Drawer
    /// 8.7, Plex 10.4), three cycles out of three.
    ///
    /// Never for a disk carrying a mounted volume we were told to leave alone:
    /// spinning down the disk under an ignored volume would break exactly the
    /// promise the ignore list makes.
    static func spinDownDecision(for disk: PhysicalDisk,
                                 unmountedThisRun: Set<String>,
                                 isIgnored: (String?) -> Bool) -> SpinDownDecision {
        guard unmountedThisRun.contains(disk.device) else { return .notThisRun }
        let mounted = disk.allVolumes.filter { $0.isMounted }
        if mounted.isEmpty { return .send }
        if mounted.contains(where: { isIgnored($0.uuid) }) { return .leftSpinningForIgnored }
        return .stillMounted
    }

    /// Finds a volume on a fresh read by its UUID, answering its device now.
    private static func relocator(_ discovery: DiskDiscovering) -> (String) -> String? {
        { uuid in
            (try? discovery.discover())?.disks.flatMap(\.allVolumes)
                .first { $0.uuid == uuid.lowercased() }?.device
        }
    }

    /// The device to act on for this volume at this moment, or nil when it
    /// cannot be found.
    ///
    /// BSD names used to come from the read at the start of the run, up to
    /// ~17 s old by the last rung of the retry ladder, with no check (audit,
    /// Low). A bay that renumbers in that window leaves its old name on a
    /// different volume or on nothing, and the next attempt would have acted
    /// on whatever was there. Now Disk Arbitration is asked, right before
    /// each operation, whether the name still holds this volume; when it does
    /// not, the volume is looked up again by UUID on a fresh read. A volume
    /// with no UUID cannot be looked up, so it is left alone.
    static func currentDevice(of volume: Volume, lastKnown: String, ops: DiskOperating,
                              relocate: (String) -> String?) -> String? {
        if ops.identifies(volume, atBSDName: lastKnown) { return lastKnown }
        guard let uuid = volume.uuid, let found = relocate(uuid),
              ops.identifies(volume, atBSDName: found) else { return nil }
        return found
    }

    /// Climbs the retry ladder for one volume. Pure function of its inputs
    /// apart from the unmount itself, so it can run on any thread.
    ///
    /// - Parameter knownHolders: holders found some other way than lsof, such
    ///   as a running Time Machine backup, named when the unmount is refused.
    private static func unmountWithRetries(_ volume: Volume, ops: DiskOperating,
                                           ladder: [TimeInterval], deadline: Date?,
                                           force: Bool, knownHolders: [String] = [],
                                           relocate: (String) -> String?,
                                           progress: (String) -> Void) -> VolumeParkResult {
        var device = volume.device
        var success = false
        var blockers: [String] = []
        var refusal: String?
        var ranOutOfTime = false
        let volumeStarted = Date()
        var usedAttempts = 0
        for (attempt, delay) in ladder.enumerated() {
            if let deadline, Date() >= deadline {
                ranOutOfTime = true
                progress("\(volume.displayName): out of time before attempt \(attempt + 1)")
                break
            }
            if delay > 0 {
                // Never sleep past the deadline waiting to retry.
                if let deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        ranOutOfTime = true
                        progress("\(volume.displayName): out of time before attempt \(attempt + 1)")
                        break
                    }
                    Thread.sleep(forTimeInterval: min(delay, remaining))
                } else {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
            guard let now = currentDevice(of: volume, lastKnown: device, ops: ops, relocate: relocate) else {
                refusal = "\(device) no longer holds \(volume.displayName) and it was not found again, "
                    + "so it was not touched"
                progress("\(volume.displayName): \(refusal ?? "")")
                break
            }
            if now != device {
                progress("\(volume.displayName) moved from \(device) to \(now)")
                device = now
            }
            progress("Unmounting \(volume.displayName), attempt \(attempt + 1)/\(ladder.count)")
            usedAttempts = attempt + 1
            if force {
                progress("Forcing \(volume.displayName) unmounted, open files will lose unwritten data")
            }
            let result = ops.unmount(volumeBSDName: device, force: force)
            if result.success { success = true; break }
            refusal = result.detail
            if let mountPoint = volume.mountPoint {
                let found = knownHolders + ops.blockers(mountPoint: mountPoint)
                if !found.isEmpty {
                    blockers = found
                    progress("\(volume.displayName) blocked by " + found.joined(separator: ", "))
                }
            }
        }
        if ranOutOfTime && blockers.isEmpty {
            blockers = ["ran out of time before macOS forced sleep"]
        }
        return VolumeParkResult(
            volume: volume, success: success, blockers: blockers,
            refusal: success ? nil : refusal,
            duration: Date().timeIntervalSince(volumeStarted),
            attempts: usedAttempts)
    }

    public func mount(onlyDisks: Set<String>? = nil,
                      progress: (String) -> Void = { _ in }) -> MountOutcome {
        runMount(scope: onlyDisks.map(Scope.disks) ?? .everything, progress: progress)
    }

    /// Mounts exactly these volumes, and lifts the veto from exactly these.
    ///
    /// For the wake path, which exists to undo an automatic park and nothing
    /// more. It used to mount everything and clear the whole veto, so a drive
    /// parked by hand came back on the next wake along with the rest (audit,
    /// Medium). A volume asked for that is no longer attached counts as not
    /// mounted rather than vanishing from the total.
    public func mount(volumeUUIDs: Set<String>,
                      progress: (String) -> Void = { _ in }) -> MountOutcome {
        runMount(scope: .volumes(Set(volumeUUIDs.map { $0.lowercased() })), progress: progress)
    }

    private func runMount(scope: Scope, progress: (String) -> Void) -> MountOutcome {
        guard let ops else {
            return MountOutcome(results: [], total: 0, mountedCount: 0,
                                failure: "Disk Arbitration session unavailable. Nothing was mounted.")
        }
        let started = Date()
        var timing = MountTiming()
        let before: DiskSnapshot
        do { before = try discovery.discover() } catch {
            return MountOutcome(results: [], total: 0, mountedCount: 0,
                                failure: "Could not read the disks, so nothing was mounted: \(error)")
        }
        timing.discover = Date().timeIntervalSince(started)
        guard let scope = Self.resolve(scope, in: before) else {
            return MountOutcome(results: [], total: 0, mountedCount: 0,
                                failure: "That drive is not on a fresh read; it may have been unplugged. Nothing was mounted.")
        }

        let disks: [PhysicalDisk]
        let inScope: (Volume) -> Bool
        var asked = 0
        switch scope {
        case .disksHolding:
            return MountOutcome(results: [], total: 0, mountedCount: 0,
                                failure: "That drive could not be found. Nothing was mounted.")
        case .everything:
            disks = before.disks
            inScope = { _ in true }
            // Drop the veto for exactly what is being mounted: all of it.
            ops.vetoedVolumeUUIDs = []
        case .disks(let names):
            disks = before.disks.filter { names.contains($0.device) }
            let unknown = names.subtracting(disks.map(\.device))
            guard unknown.isEmpty else {
                return MountOutcome(results: [], total: 0, mountedCount: 0,
                                    failure: "No external disk named \(unknown.sorted().joined(separator: ", ")). Nothing was mounted.")
            }
            inScope = { _ in true }
            let lifting = Set(disks.flatMap(\.allVolumes).compactMap { $0.uuid?.lowercased() })
            ops.vetoedVolumeUUIDs = ops.vetoedVolumeUUIDs.subtracting(lifting)
        case .volumes(let uuids):
            disks = before.disks.filter { $0.allVolumes.contains { $0.uuid.map(uuids.contains) ?? false } }
            inScope = { $0.uuid.map(uuids.contains) ?? false }
            asked = uuids.filter { !isIgnored($0) }.count
            let lifting = ops.vetoedVolumeUUIDs.intersection(uuids)
            if !lifting.isEmpty { ops.vetoedVolumeUUIDs = ops.vetoedVolumeUUIDs.subtracting(lifting) }
        }
        let targets = disks.flatMap(\.allVolumes).filter { inScope($0) && !isIgnored($0.uuid) }
        let targetDevices = Set(targets.map(\.device))

        // Concurrent per disk, for the same reason the park is. Measured
        // 2026-09-08 with the drives spun down after a park: each mount sat 8
        // to 12 s in diskarbitrationd's probe, which is the platters coming
        // back up, and the mount itself took a tenth of a second after that.
        // Three spin-ups in sequence was 33.7 s. Three at once cost the
        // slowest one. No approval timeout here (Ejectify's callback was on
        // unmount), so what remains is physics.
        let mountStarted = Date()
        let relocate = Self.relocator(discovery)
        let lock = NSLock()
        var indexed: [(disk: Int, volume: Int, result: VolumeMountResult)] = []
        withoutActuallyEscaping(progress) { progress in
            let report: (String) -> Void = { line in
                lock.lock(); defer { lock.unlock() }
                progress(line)
            }
            DispatchQueue.concurrentPerform(iterations: disks.count) { diskIndex in
                let disk = disks[diskIndex]
                for (volumeIndex, volume) in disk.allVolumes.enumerated()
                where !volume.isMounted && targetDevices.contains(volume.device) {
                    report("Mounting \(volume.displayName)")
                    let volumeStarted = Date()
                    // Same check as the unmount: the read this mount started
                    // from can be older than the bay's current name.
                    let result: OpResult
                    if let device = Self.currentDevice(of: volume, lastKnown: volume.device,
                                                       ops: ops, relocate: relocate) {
                        result = ops.mount(volumeBSDName: device)
                    } else {
                        result = OpResult(success: false,
                                          detail: "\(volume.device) no longer holds this volume and it was not found again")
                    }
                    let duration = Date().timeIntervalSince(volumeStarted)
                    if !result.success {
                        report("\(volume.displayName) failed: \(result.detail ?? "unknown")")
                    }
                    lock.lock()
                    indexed.append((diskIndex, volumeIndex, VolumeMountResult(
                        volume: volume, success: result.success,
                        detail: result.detail, duration: duration)))
                    lock.unlock()
                }
            }
        }
        let results = indexed
            .sorted { ($0.disk, $0.volume) < ($1.disk, $1.volume) }
            .map { $0.result }
        timing.mount = Date().timeIntervalSince(mountStarted)

        // VERIFY with a fresh read, by UUID, like the park.
        let verifyStarted = Date()
        let after: DiskSnapshot
        do { after = try discovery.discover() } catch {
            timing.verify = Date().timeIntervalSince(verifyStarted)
            timing.total = Date().timeIntervalSince(started)
            return MountOutcome(results: results, total: max(targets.count, asked), mountedCount: 0,
                                timing: timing,
                                failure: "Asked macOS to mount, but could not verify: \(error)")
        }
        let afterVolumes = after.disks.flatMap(\.allVolumes)
        let mountedCount = targets.filter { target in
            afterVolumes.contains { now in
                now.isMounted && (target.uuid.map { $0 == now.uuid } ?? (now.device == target.device))
            }
        }.count
        timing.verify = Date().timeIntervalSince(verifyStarted)
        timing.total = Date().timeIntervalSince(started)
        return MountOutcome(results: results, total: max(targets.count, asked),
                            mountedCount: mountedCount, timing: timing)
    }
}
