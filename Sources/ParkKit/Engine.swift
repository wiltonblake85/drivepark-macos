// Engine.swift — the unmount-verify-park loop, shared by CLI and app.

import Foundation

public struct VolumeParkResult {
    public let volume: Volume
    public let success: Bool
    public let blockers: [String]
}

public struct ParkOutcome {
    public let results: [VolumeParkResult]
    public let stillMounted: [Volume]
    public let notes: [String]
    public var parked: Bool { stillMounted.isEmpty }

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

    public func park(onlyDisks: Set<String>? = nil,
                     progress: (String) -> Void = { _ in }) -> ParkOutcome {
        guard let ops else {
            return ParkOutcome(results: [], stillMounted: [],
                               notes: ["Disk Arbitration session unavailable"])
        }
        let disks = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        var vetoUUIDs: Set<String> = []
        for disk in disks {
            for volume in disk.allVolumes {
                if let uuid = volumeUUID(of: volume.device) {
                    vetoUUIDs.insert(uuid.lowercased())
                }
            }
        }

        var results: [VolumeParkResult] = []
        for disk in disks {
            for volume in disk.allVolumes where volume.isMounted {
                    var success = false
                    var blockers: [String] = []
                    for (attempt, delay) in Self.retryDelays.enumerated() {
                        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                        progress("Unmounting \(volume.displayName), attempt \(attempt + 1)/\(Self.retryDelays.count)")
                        let result = ops.unmount(volumeBSDName: volume.device)
                        if result.success { success = true; break }
                        if let mountPoint = volume.mountPoint {
                            let found = lsofBlockers(mountPoint: mountPoint)
                            if !found.isEmpty {
                                blockers = found
                                progress("\(volume.displayName) blocked by " + found.joined(separator: ", "))
                            }
                        }
                    }
                results.append(VolumeParkResult(volume: volume, success: success, blockers: blockers))
            }
        }

        // VERIFY with a fresh read. Never trust the callbacks alone.
        let after = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        let stillMounted = after.flatMap { $0.allVolumes }.filter { $0.isMounted }

        // Courtesy spin-down for each fully-unmounted physical disk.
        var notes: [String] = []
        for disk in after {
            let anyMounted = disk.allVolumes.contains { $0.isMounted }
            guard !anyMounted else { continue }
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

        // Arm the remount veto only after a fully verified park.
        if stillMounted.isEmpty { parkedVolumeUUIDs = vetoUUIDs }
        return ParkOutcome(results: results, stillMounted: stillMounted, notes: notes)
    }

    public func release(onlyDisks: Set<String>? = nil,
                        progress: (String) -> Void = { _ in }) -> (mounted: Int, total: Int) {
        parkedVolumeUUIDs = []
        guard let ops else { return (0, 0) }
        let disks = discoverExternalDisks()
            .filter { onlyDisks?.contains($0.device) ?? true }
        for disk in disks {
            for volume in disk.allVolumes where !volume.isMounted {
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
        return (after.filter { $0.isMounted }.count, after.count)
    }
}
