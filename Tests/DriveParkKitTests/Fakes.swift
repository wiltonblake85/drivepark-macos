// Fakes.swift: stand-ins for the disks, so the engine's decisions run where a
// stalled enclosure can be produced on cue.
//
// Nothing here touches Disk Arbitration, diskutil or the preferences of the
// Mac running the tests. The engine reaches all three through what it is
// given in its initializer.

import Foundation
@testable import DriveParkKit

/// A read that did not finish, the way diskutil fails on a stalled bridge.
struct StalledRead: Error, CustomStringConvertible {
    var description: String { "diskutil list -plist external physical did not answer in 10s" }
}

/// Answers each `discover()` with the next scripted read; the last one repeats.
final class FakeDiscovery: DiskDiscovering {
    private let lock = NSLock()
    private let reads: [Result<DiskSnapshot, Error>]
    private var count = 0
    var images: [AttachedImage]? = []

    init(_ reads: [Result<DiskSnapshot, Error>]) {
        self.reads = reads
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func discover() throws -> DiskSnapshot {
        lock.lock()
        let read = reads[min(count, reads.count - 1)]
        count += 1
        lock.unlock()
        return try read.get()
    }

    func attachedImages() -> [AttachedImage]? { images }
}

/// Records every operation in order. Succeeds unless told otherwise.
final class FakeOps: DiskOperating {
    private let lock = NSLock()
    private var log: [String] = []
    private var veto: Set<String> = []
    /// Unmount answers by device, for refusals.
    var unmountAnswers: [String: OpResult] = [:]
    /// Who lsof would name, by mount point.
    var holders: [String: [String]] = [:]

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ event: String) {
        lock.lock(); log.append(event); lock.unlock()
    }

    func unmount(volumeBSDName: String, force: Bool) -> OpResult {
        record("unmount \(volumeBSDName)\(force ? " force" : "")")
        lock.lock(); defer { lock.unlock() }
        return unmountAnswers[volumeBSDName] ?? OpResult(success: true)
    }

    func mount(volumeBSDName: String) -> OpResult {
        record("mount \(volumeBSDName)")
        return OpResult(success: true)
    }

    func eject(diskBSDName: String) -> OpResult {
        record("eject \(diskBSDName)")
        return OpResult(success: true)
    }

    /// Fixed media: an eject never detaches.
    func isAttached(diskBSDName: String) -> Bool { true }

    func blockers(mountPoint: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return holders[mountPoint] ?? []
    }

    var vetoedVolumeUUIDs: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return veto }
        set {
            lock.lock()
            veto = newValue
            log.append("veto [\(newValue.sorted().joined(separator: ","))]")
            lock.unlock()
        }
    }
}

/// The tower's three APFS bays as captured on 2026-10-06, each its own
/// container, with the device names they had that day. Bottom Drawer's UUID
/// is its real one; the other two stand in. Lowercased, the way discovery
/// stores them.
enum Tower {
    static let bottomDrawer = "c79bdc4e-55a9-48ce-be31-dae64c36bc15"
    static let plex = "9e47a6a5-7f41-406f-821d-eca483c3dcb1"
    static let backup = "5b0f3a2e-1c44-4b8e-9d0a-6f2c8e7d1a90"

    struct Bay {
        var disk: String
        var container: String
        var volume: String
        var name: String
        var uuid: String
    }

    static let bays = [
        Bay(disk: "disk21", container: "disk22", volume: "disk22s1", name: " Bottom Drawer", uuid: bottomDrawer),
        Bay(disk: "disk23", container: "disk24", volume: "disk24s1", name: "Plex", uuid: plex),
        Bay(disk: "disk25", container: "disk26", volume: "disk26s1", name: "Backup", uuid: backup),
    ]

    /// The tower with the named volumes mounted at /Volumes/<name>.
    static func snapshot(mounted: Set<String> = [], bays: [Bay] = bays,
                         unaccounted: [UnaccountedMount] = []) -> DiskSnapshot {
        let disks = bays.map { bay -> PhysicalDisk in
            var disk = PhysicalDisk(device: bay.disk)
            let point = mounted.contains(bay.uuid)
                ? "/Volumes/\(bay.name.trimmingCharacters(in: .whitespaces))" : nil
            disk.containers = [Container(device: bay.container, physicalStore: bay.disk + "s2",
                                         volumes: [Volume(device: bay.volume, name: bay.name,
                                                          mountPoint: point, uuid: bay.uuid)])]
            return disk
        }
        return DiskSnapshot(disks: disks, unaccountedMounts: unaccounted)
    }

    static let all: Set<String> = [bottomDrawer, plex, backup]
}

func engine(_ discovery: FakeDiscovery, _ ops: FakeOps,
            ignored: @escaping (String?) -> Bool = { _ in false }) -> Engine {
    Engine(discovery: discovery, ops: ops, isIgnored: ignored, retryDelays: [0])
}
