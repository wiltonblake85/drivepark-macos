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
    runPlistTool("/usr/sbin/diskutil", args, timeout: timeout,
                 onTimeout: DiskutilTimeout.record)
}

/// The same discipline for any tool that prints a plist. hdiutil gets it too:
/// a tool that must not hang on a stuck enclosure must not hang on a stuck
/// disk image either.
func runPlistTool(_ executable: String, _ args: [String],
                  timeout: TimeInterval = 10,
                  onTimeout: () -> Void = {}) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }

    let readers = DispatchQueue(label: "drivepark.plisttool.read", attributes: .concurrent)
    let group = DispatchGroup()
    let box = DataBox()
    readers.async(group: group) {
        box.set(out.fileHandleForReading.readDataToEndOfFile())
    }
    readers.async(group: group) {
        _ = err.fileHandleForReading.readDataToEndOfFile()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        onTimeout()
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
    /// Stable identity across replug and renumbering. `diskutil list -plist`
    /// carries VolumeUUID for APFS volumes AND for plain partitions, so this
    /// costs no extra process launch.
    ///
    /// It has to be the volume, not the disk: on the TerraMaster DAS all three
    /// bays report the same IORegistryEntryName, the same MediaName and the
    /// same DeviceTreePath, and two of them the same byte size. There is no
    /// whole-disk serial to key on.
    public let uuid: String?
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
    // Disk images are opt-in, and dropping `physical` is NOT how you opt in.
    //
    // Measured on the tower 2026-09-04: `diskutil list external physical`
    // returns 3 whole disks, and `diskutil list external` returns 22. Sixteen
    // of the extra nineteen are disk images. The other three are the APFS
    // synthesized containers that the loop further down already maps back to
    // their physical stores, so admitting them as whole disks would count every
    // volume twice and offer to eject a container.
    //
    // So the wide list is a candidate list, not an answer. Each candidate is
    // kept only if diskutil calls it a Disk Image and it is not a synthesized
    // container (see below), which costs nothing extra
    // because the info call below already runs for every disk.
    //
    // `external` itself is never relaxed. It is the one thing keeping the boot
    // disk out of a tool that unmounts volumes, and on this Mac the internal
    // SSD reports Device Location: Internal.
    //
    // PARK_INCLUDE_VIRTUAL=1 still forces it on, because the filesystem tests
    // and the manage-list work run against scratch images and predate the
    // setting.
    let includeImages = Preferences.includeDiskImages
        || ProcessInfo.processInfo.environment["PARK_INCLUDE_VIRTUAL"] == "1"

    DiskutilTimeout.reset()
    guard let physicalList = runDiskutil(["list", "-plist", "external", "physical"]),
          let physicalWhole = physicalList["WholeDisks"] as? [String] else {
        return []
    }
    var externalSet = Set(physicalWhole)
    var imageCandidates: Set<String> = []
    if includeImages,
       let wideList = runDiskutil(["list", "-plist", "external"]),
       let wideWhole = wideList["WholeDisks"] as? [String] {
        imageCandidates = Set(wideWhole).subtracting(externalSet)
        externalSet.formUnion(imageCandidates)
    }

    guard let fullList = runDiskutil(["list", "-plist"]),
          let allEntries = fullList["AllDisksAndPartitions"] as? [[String: Any]]
    else { return [] }

    // Every APFS synthesized container, whatever it sits on. The protocol
    // filter below was trusted to keep these out, and for the tower's own
    // containers it does. For a container inside a disk image it does not:
    // measured 2026-09-10, disk11, the container inside the iOS 26.2 Simulator
    // image disk10, reports Protocol: Disk Image exactly like its parent. It
    // was admitted as a whole disk with no volumes of its own, which is what
    // put eight blank "— ignored" rows in the menu.
    let synthesized = Set(allEntries.compactMap { entry -> String? in
        guard entry["APFSPhysicalStores"] != nil else { return nil }
        return entry["DeviceIdentifier"] as? String
    })

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
        // A candidate from the wide list earns its place only by being a real
        // disk image. Anything else there is a synthesized container, and an
        // enclosure that will not answer an info query is not evidence of
        // either, so it does not get the benefit of the doubt.
        if imageCandidates.contains(device),
           synthesized.contains(device)
            || !(disk.infoAnswered && disk.busProtocol == "Disk Image") {
            continue
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
                    mountPoint: mountPoint,
                    uuid: (partition["VolumeUUID"] as? String)?.lowercased()))
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
                    mountPoint: volumeEntry["MountPoint"] as? String,
                    uuid: (volumeEntry["VolumeUUID"] as? String)?.lowercased()))
            }
        }
        disks[physicalDisk]?.containers.append(Container(
            device: containerDevice,
            physicalStore: firstStore,
            volumes: volumes))
    }
    // Images macOS attached for its own use are never a drive, with the
    // setting on or off. Measured 2026-09-10: Xcode keeps eight simulator
    // runtimes attached, 17 GB each, mounted under
    // /Library/Developer/CoreSimulator/Volumes. With images on they counted as
    // eight of eleven volumes, every park tried to unmount them out from under
    // CoreSimulator, and every park failed on them. Nothing a person does
    // about the tower changes whether they are attached, so they have no
    // business in the safe-to-unplug answer.
    if !imageCandidates.isEmpty {
        let backing = readAttachedImages() ?? []
        for device in imageCandidates {
            guard let disk = disks[device] else { continue }
            let path = backing.first { $0.wholeDisk == device }?.resolvedImagePath
            let points = disk.allVolumes.compactMap { $0.mountPoint }
            if isSystemManagedImage(backingPath: path, mountPoints: points) {
                disks[device] = nil
            }
        }
    }
    return disks.keys.sorted().compactMap { disks[$0] }
}

/// Where macOS keeps disk images it attaches for itself. Simulator runtimes
/// live under the first two on this Mac: Xcode 26 downloads them as
/// MobileAssets under /System/Library/AssetsV2, and older runtimes sit in
/// /Library/Developer/CoreSimulator/Images.
let systemImagePrefixes = ["/System/", "/Library/Developer/CoreSimulator/"]

/// True for a disk image the system attached for its own use rather than one a
/// person opened.
///
/// Two independent signals, either one enough. The backing path says who owns
/// the file. The mount point says who mounted the volume: a .dmg a person
/// opens mounts under /Volumes, and one mounted anywhere else was put there by
/// something that expects it to stay. The second signal still works when
/// hdiutil does not answer, which is why the path is optional.
///
/// An image with nothing mounted and no known backing path stays in. That is
/// a parked .dmg, and dropping it would hide the Mount action for it.
public func isSystemManagedImage(backingPath: String?, mountPoints: [String]) -> Bool {
    if let backingPath,
       systemImagePrefixes.contains(where: { backingPath.hasPrefix($0) }) {
        return true
    }
    return mountPoints.contains { !$0.hasPrefix("/Volumes/") }
}
