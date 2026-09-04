// Engine.swift — the unmount-verify-park loop, shared by CLI and app.

import Foundation

public struct VolumeParkResult {
    public let volume: Volume
    public let success: Bool
    public let blockers: [String]
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
    public var unmount: TimeInterval = 0
    public var verify: TimeInterval = 0
    public var spinDown: TimeInterval = 0
    public var total: TimeInterval = 0

    public var summary: String {
        String(format: "%.2fs total (discover %.2f, unmount %.2f, verify %.2f, spin-down %.2f)",
               total, discover, unmount, verify, spinDown)
    }
}

public struct ParkOutcome {
    public let results: [VolumeParkResult]
    public let stillMounted: [Volume]
    public let notes: [String]
    public var timing = ParkTiming()
    /// True when nothing DrivePark manages is left mounted.
    ///
    /// Not the same as "this run parked something". A run that unmounted
    /// nothing, because every volume was ignored or already unmounted, also
    /// satisfies this, and calling that a park is how a tool ends up printing
    /// "Nothing to park" and "PARKED" one line apart. Ask `didWork` too.
    public var parked: Bool { stillMounted.isEmpty }

    /// True when this run actually unmounted something and verified it.
    public var didWork: Bool { !results.isEmpty }

    public var blockerSummary: String? {
        let failed = results.filter { !$0.success && !$0.blockers.isEmpty }
        guard !failed.isEmpty else { return nil }
        return failed.map { "\($0.volume.displayName): \($0.blockers.joined(separator: ", "))" }
            .joined(separator: "; ")
    }
}

public final class Engine {
    private let ops: DiskOps?
    static let retryDelays: [TimeInterval] = [0, 2, 5, 10]

    public init() {
        ops = DiskOps()
        // The veto is registered once and gated by parkedVolumeUUIDs:
        // empty set = inert, populated after a full park = active hold.
        ops?.startMountVeto()
    }

    public func discover() -> [PhysicalDisk] {
        discoverExternalDisks()
    }

    public var isVetoActive: Bool { !parkedVolumeUUIDs.isEmpty }

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
    public func park(onlyDisks: Set<String>? = nil,
                     deadline: Date? = nil,
                     force: Bool = false,
                     progress: (String) -> Void = { _ in }) -> ParkOutcome {
        guard let ops else {
            return ParkOutcome(results: [], stillMounted: [],
                               notes: ["Disk Arbitration session unavailable"])
        }
        let started = Date()
        var timing = ParkTiming()
        let discoverStarted = Date()
        let disks = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        timing.discover = Date().timeIntervalSince(discoverStarted)

        // The ignore list is absolute. Not overridden by naming the drive, not
        // overridden by Park Tower. A volume you told DrivePark to leave alone
        // is one it must not unmount while something is mid-copy on it, and an
        // override that one click can reach is not a guarantee.
        var skipped: [Volume] = []
        var vetoUUIDs: Set<String> = []
        for disk in disks {
            for volume in disk.allVolumes {
                guard let uuid = volume.uuid else { continue }
                if Preferences.isIgnored(uuid) {
                    skipped.append(volume)
                } else {
                    vetoUUIDs.insert(uuid.lowercased())
                }
            }
        }

        // Force does not climb the retry ladder. The ladder exists to wait a
        // blocker out; force refuses to wait, so retrying it is just repeating
        // the same violence.
        let ladder = force ? [TimeInterval(0)] : Self.retryDelays

        var results: [VolumeParkResult] = []
        let unmountStarted = Date()
        for disk in disks {
            for volume in disk.allVolumes
            where volume.isMounted && !Preferences.isIgnored(volume.uuid) {
                    var success = false
                    var blockers: [String] = []
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
                        progress("Unmounting \(volume.displayName), attempt \(attempt + 1)/\(ladder.count)")
                        usedAttempts = attempt + 1
                        if force {
                            progress("Forcing \(volume.displayName) unmounted, open files will lose unwritten data")
                        }
                        let result = ops.unmount(volumeBSDName: volume.device, force: force)
                        if result.success { success = true; break }
                        if let mountPoint = volume.mountPoint {
                            let found = lsofBlockers(mountPoint: mountPoint)
                            if !found.isEmpty {
                                blockers = found
                                progress("\(volume.displayName) blocked by " + found.joined(separator: ", "))
                            }
                        }
                    }
                    if ranOutOfTime && blockers.isEmpty {
                        blockers = ["ran out of time before macOS forced sleep"]
                    }
                results.append(VolumeParkResult(
                    volume: volume, success: success, blockers: blockers,
                    duration: Date().timeIntervalSince(volumeStarted),
                    attempts: usedAttempts))
            }
        }

        timing.unmount = Date().timeIntervalSince(unmountStarted)

        // VERIFY with a fresh read. Never trust the callbacks alone.
        let verifyStarted = Date()
        let after = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        let stillMounted = after.flatMap { $0.allVolumes }
            .filter { $0.isMounted && !Preferences.isIgnored($0.uuid) }

        timing.verify = Date().timeIntervalSince(verifyStarted)

        var notes: [String] = []
        for volume in skipped {
            notes.append("\(volume.displayName): left alone, on the ignore list")
        }

        let spinStarted = Date()
        // Courtesy spin-down, but never for a disk carrying a mounted volume
        // we were told to leave alone. Spinning down the disk under an ignored
        // volume would break exactly the promise the ignore list makes.
        for disk in after {
            let anyMounted = disk.allVolumes.contains { $0.isMounted }
            guard !anyMounted else {
                if disk.allVolumes.contains(where: { $0.isMounted && Preferences.isIgnored($0.uuid) }) {
                    notes.append("\(disk.device): left spinning, it carries an ignored volume that is still mounted")
                }
                continue
            }
            let result = ops.eject(diskBSDName: disk.device)
            let attached = ops.isAttached(diskBSDName: disk.device)
            if result.success && attached {
                notes.append("\(disk.device): spin-down sent; still attached (fixed media, expected)")
            } else if result.success {
                notes.append("\(disk.device): ejected and detached")
            } else {
                notes.append("\(disk.device): spin-down refused: \(result.detail ?? "unknown")")
            }
        }

        // Arm the remount veto only after a fully verified park. Union, so
        // per-drive parks accumulate instead of replacing each other.
        //
        // `results` being empty means this run unmounted nothing, so there is
        // nothing it verified and nothing to stand behind. Arming on that
        // turned a stray park against already-unmounted drives into a standing
        // veto nobody asked for, and nothing on screen said so.
        timing.spinDown = Date().timeIntervalSince(spinStarted)
        timing.total = Date().timeIntervalSince(started)

        if stillMounted.isEmpty && !results.isEmpty {
            parkedVolumeUUIDs.formUnion(vetoUUIDs)
            // Say out loud who is holding it. The veto lives in this process's
            // memory and no other process can lift it, so a second process
            // needs to be able to find out that this one exists.
            VetoBroker.publishHold(parkedVolumeUUIDs)
        } else if stillMounted.isEmpty && results.isEmpty {
            notes.append("Nothing to park: no managed volume was mounted. Veto left as it was.")
        }
        return ParkOutcome(results: results, stillMounted: stillMounted,
                           notes: notes, timing: timing)
    }

    public func release(onlyDisks: Set<String>? = nil,
                        progress: (String) -> Void = { _ in }) -> (mounted: Int, total: Int) {
        guard let ops else { return (0, 0) }
        let disks = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        // Drop the veto for exactly what is being released.
        if onlyDisks == nil {
            parkedVolumeUUIDs = []
        } else {
            for disk in disks {
                for volume in disk.allVolumes {
                    if let uuid = volume.uuid {
                        parkedVolumeUUIDs.remove(uuid.lowercased())
                    }
                }
            }
        }
        VetoBroker.publishHold(parkedVolumeUUIDs)
        for disk in disks {
            for volume in disk.allVolumes
            where !volume.isMounted && !Preferences.isIgnored(volume.uuid) {
                progress("Mounting \(volume.displayName)")
                let result = ops.mount(volumeBSDName: volume.device)
                if !result.success {
                    progress("\(volume.displayName) failed: \(result.detail ?? "unknown")")
                }
            }
        }
        // VERIFY with a fresh read.
        let after = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
            .flatMap { $0.allVolumes }
            .filter { !Preferences.isIgnored($0.uuid) }
        return (after.filter { $0.isMounted }.count, after.count)
    }
}
