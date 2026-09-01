// Discovery.swift — read-only discovery of external disks via diskutil plists.

import Foundation

/// Set when the last diskutil call gave up waiting. Read it right after a
/// discovery to tell "this enclosure answered and has nothing" apart from
/// "this enclosure stopped answering".
public struct DiskutilTimeout {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func record() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }

    public static var occurred: Bool {
        lock.lock(); defer { lock.unlock() }
        return count > 0
    }

    public static var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Runs diskutil and gives up rather than waiting forever.
///
/// Observed on the TerraMaster DAS on 2026-08-31: the bridge stopped answering
/// `diskutil info` on all three bays while `diskutil list` and `df` kept
/// working. Every caller blocked in read() forever. A tool whose whole promise
/// is telling the truth about stuck drives must not itself hang on one.
///
/// Both pipes are drained. Reading stdout while leaving stderr undrained
/// deadlocks as soon as a command is verbose enough to fill that buffer.
func runDiskutil(_ args: [String], timeout: TimeInterval = 10) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }

    let readers = DispatchQueue(label: "drivepark.diskutil.read", attributes: .concurrent)
    let group = DispatchGroup()
    let box = DataBox()
    readers.async(group: group) {
        box.set(out.fileHandleForReading.readDataToEndOfFile())
    }
    readers.async(group: group) {
        _ = err.fileHandleForReading.readDataToEndOfFile()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        DiskutilTimeout.record()
        process.terminate()
        if group.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
            // A process blocked in the kernel on an unresponsive USB bridge
            // does not always answer SIGTERM.
            kill(process.processIdentifier, SIGKILL)
        }
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let plist = try? PropertyListSerialization.propertyList(
              from: box.get(), options: [], format: nil) else { return nil }
    return plist as? [String: Any]
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

func volumeUUID(of device: String) -> String? {
    runDiskutil(["info", "-plist", device])?["VolumeUUID"] as? String
}

func wholeDiskName(of device: String) -> String {
    guard let match = device.range(of: "^disk[0-9]+", options: .regularExpression)
    else { return device }
    return String(device[match])
}

public struct Volume {
    public let device: String
    public let name: String
    public let mountPoint: String?
    public var isMounted: Bool { mountPoint != nil }
    public var displayName: String { name.trimmingCharacters(in: .whitespaces) }
}

public struct Container {
    public let device: String
    public let physicalStore: String
    public var volumes: [Volume]
}

public struct PhysicalDisk {
    public let device: String
    public var mediaName = "?"
    public var busProtocol = "?"
    public var sizeBytes: Int64 = 0
    public var removableMedia = false
    public var ejectable = false
    /// False when `diskutil info` for this disk timed out. The disk still
    /// exists and its volumes are still known from `diskutil list`; what is
    /// missing is the detail, and saying so beats printing "?" as if it were
    /// an answer.
    public var infoAnswered = true
    public var containers: [Container] = []
    public var directVolumes: [Volume] = []

    /// Every volume on this disk: APFS container volumes plus direct
    /// (non-APFS) partitions such as exFAT, FAT32, NTFS, or HFS+.
    public var allVolumes: [Volume] { containers.flatMap { $0.volumes } + directVolumes }
}

public func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    return formatter.string(fromByteCount: bytes)
}

public func discoverExternalDisks() -> [PhysicalDisk] {
    // PARK_INCLUDE_VIRTUAL=1 includes attached disk images, used for
    // filesystem tests without real hardware.
    let includeVirtual = ProcessInfo.processInfo.environment["PARK_INCLUDE_VIRTUAL"] == "1"
    let listArguments = includeVirtual
        ? ["list", "-plist", "external"]
        : ["list", "-plist", "external", "physical"]
    DiskutilTimeout.reset()
    guard let externalList = runDiskutil(listArguments),
          let externalWhole = externalList["WholeDisks"] as? [String] else {
        return []
    }
    let externalSet = Set(externalWhole)

    guard let fullList = runDiskutil(["list", "-plist"]),
          let allEntries = fullList["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    var disks: [String: PhysicalDisk] = [:]
    for device in externalSet.sorted() {
        var disk = PhysicalDisk(device: device)
        if let info = runDiskutil(["info", "-plist", device]) {
            disk.mediaName = info["MediaName"] as? String ?? "?"
            disk.busProtocol = info["BusProtocol"] as? String ?? "?"
            if let size = info["TotalSize"] as? Int64 { disk.sizeBytes = size }
            else if let size = info["TotalSize"] as? Int { disk.sizeBytes = Int64(size) }
            disk.removableMedia = info["RemovableMedia"] as? Bool
                ?? info["Removable"] as? Bool ?? false
            disk.ejectable = info["Ejectable"] as? Bool ?? false
        } else {
            disk.infoAnswered = false
        }
        disks[device] = disk
    }

    let skippedContent: Set<String> = [
        "EFI", "Microsoft Reserved", "Apple_APFS", "Apple_APFS_ISC",
        "Apple_APFS_Recovery", "Apple_Boot", "Apple_CoreStorage",
        "Apple_KernelCoreDump", "Windows Recovery", "Linux Swap"
    ]
    for entry in allEntries {
        guard let entryDevice = entry["DeviceIdentifier"] as? String else { continue }

        // Direct (non-APFS) partitions on an external disk: exFAT, FAT32,
        // NTFS, HFS+, and similar mountable volumes.
        if disks[entryDevice] != nil,
           let partitions = entry["Partitions"] as? [[String: Any]] {
            for partition in partitions {
                guard let partitionDevice = partition["DeviceIdentifier"] as? String
                else { continue }
                let content = partition["Content"] as? String ?? ""
                guard !skippedContent.contains(content) else { continue }
                let name = partition["VolumeName"] as? String
                let mountPoint = partition["MountPoint"] as? String
                guard name != nil || mountPoint != nil else { continue }
                disks[entryDevice]?.directVolumes.append(Volume(
                    device: partitionDevice,
                    name: name ?? "(unnamed)",
                    mountPoint: mountPoint))
            }
        }

        // Synthesized APFS containers mapped to their physical store.
        let containerDevice = entryDevice
        guard let stores = entry["APFSPhysicalStores"] as? [[String: Any]],
              let firstStore = stores.first?["DeviceIdentifier"] as? String
        else { continue }
        let physicalDisk = wholeDiskName(of: firstStore)
        guard disks[physicalDisk] != nil else { continue }

        var volumes: [Volume] = []
        if let apfsVolumes = entry["APFSVolumes"] as? [[String: Any]] {
            for volumeEntry in apfsVolumes {
                guard let volumeDevice = volumeEntry["DeviceIdentifier"] as? String
                else { continue }
                volumes.append(Volume(
                    device: volumeDevice,
                    name: volumeEntry["VolumeName"] as? String ?? "(unnamed)",
                    mountPoint: volumeEntry["MountPoint"] as? String))
            }
        }
        disks[physicalDisk]?.containers.append(Container(
            device: containerDevice,
            physicalStore: firstStore,
            volumes: volumes))
    }
    return disks.keys.sorted().compactMap { disks[$0] }
}
