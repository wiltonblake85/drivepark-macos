// Discovery.swift: read-only discovery of external disks via diskutil plists.

import Foundation
import IOKit

public struct Volume: Equatable {
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
    /// The name for showing to a person: trimmed, and with anything that
    /// could forge or hide a line escaped (see printable). `name` stays raw
    /// for the few places that must match it exactly.
    public var displayName: String { printable(name.trimmingCharacters(in: .whitespaces)) }
    /// The mount point for showing to a person. A mount point is usually the
    /// volume name under /Volumes, so it carries whatever the name carries.
    public var displayMountPoint: String? { mountPoint.map(printable) }
}

public struct Container: Equatable {
    public let device: String
    public let physicalStore: String
    public var volumes: [Volume]
}

public struct PhysicalDisk: Equatable {
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
    /// (non-APFS) partitions such as exFAT, FAT32, NTFS, or HFS+, plus a
    /// volume written straight onto the whole disk.
    public var allVolumes: [Volume] { containers.flatMap { $0.volumes } + directVolumes }
}

/// One fresh read of the external disks.
public struct DiskSnapshot {
    public var disks: [PhysicalDisk]
    /// Mounts the kernel reports that this read could not account for. Any
    /// entry here means the enclosure is not safe to power off, whatever the
    /// volume list says.
    public var unaccountedMounts: [UnaccountedMount]

    public init(disks: [PhysicalDisk], unaccountedMounts: [UnaccountedMount] = []) {
        self.disks = disks
        self.unaccountedMounts = unaccountedMounts
    }

    public var verdict: PowerOffVerdict {
        PowerOffVerdict(disks: disks, unaccountedMounts: unaccountedMounts)
    }
}

/// A read that did not finish.
///
/// Thrown, never returned as an empty list. On 2026-10-05 the audit traced a
/// park reported as safe while three volumes were still mounted to exactly
/// that: discovery answered `[]` when diskutil timed out, and the verify step
/// read `[]` as "nothing left mounted".
public struct DiscoveryFailure: Error, CustomStringConvertible {
    public let reason: String
    /// True when a tool stopped answering, which on the tower has meant the
    /// enclosure's bridge stalled.
    public let timedOut: Bool
    /// What the read did learn, for display. Never a basis for a verdict.
    public let partial: [PhysicalDisk]

    public init(reason: String, timedOut: Bool = false, partial: [PhysicalDisk] = []) {
        self.reason = reason
        self.timedOut = timedOut
        self.partial = partial
    }

    public var description: String { reason }
}

func wholeDiskName(of device: String) -> String {
    guard let match = device.range(of: "^disk[0-9]+", options: .regularExpression)
    else { return device }
    return String(device[match])
}

public func formatSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    return formatter.string(fromByteCount: bytes)
}

/// The running system's own mount points. DrivePark never unmounts one,
/// whatever discovery says about the disk under it (audit H3).
public func isProtectedMountPoint(_ path: String?) -> Bool {
    guard let path else { return false }
    return path == "/" || path.hasPrefix("/System/Volumes/")
}

/// APFS roles that belong to an operating system rather than to anyone's
/// files. On an external disk that holds a macOS install these never mount on
/// their own; offering to park or mount them would be wrong in both
/// directions. System and Data stay: those are what a person sees in Finder
/// when they attach a bootable backup.
let systemVolumeRoles: Set<String> = [
    "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband", "Prelogin"
]

/// Partition types whose filesystem appears as a separate virtual disk.
let virtualMemberContent: Set<String> = ["Apple_RAID", "Apple_RAID_Offline", "Apple_CoreStorage"]

public func discoverExternalDisks() throws -> DiskSnapshot {
    // Disk images are opt-in, and dropping `physical` is NOT how you opt in.
    //
    // Measured on the tower 2026-09-04: `diskutil list external physical`
    // returns 3 whole disks, and `diskutil list external` returns 22. Sixteen
    // of the extra nineteen are disk images. The other three are the APFS
    // synthesized containers that assembleDisks already maps back to their
    // physical stores, so admitting them as whole disks would count every
    // volume twice and offer to eject a container.
    //
    // PARK_INCLUDE_VIRTUAL=1 still forces it on, because the filesystem tests
    // and the manage-list work run against scratch images and predate the
    // setting.
    let includeImages = Preferences.includeDiskImages
        || ProcessInfo.processInfo.environment["PARK_INCLUDE_VIRTUAL"] == "1"

    var problems: [String] = []
    var timedOut = false
    func take(_ read: PlistRead) -> [String: Any]? {
        switch read {
        case .plist(let value):
            return value
        case .failed(let reason, let stalled):
            problems.append(reason)
            if stalled { timedOut = true }
            return nil
        }
    }
    func failure(_ partial: [PhysicalDisk] = []) -> DiscoveryFailure {
        DiscoveryFailure(reason: problems.joined(separator: "; "),
                         timedOut: timedOut, partial: partial)
    }

    guard let physicalList = take(diskutil(["list", "-plist", "external", "physical"]))
    else { throw failure() }
    var wideList: [String: Any]?
    if includeImages {
        // A .dmg the user said counts as a drive cannot be quietly left out
        // of the answer because this one call failed.
        guard let wide = take(diskutil(["list", "-plist", "external"])) else { throw failure() }
        wideList = wide
    }
    guard let fullList = take(diskutil(["list", "-plist"])) else { throw failure() }
    guard let bootInfo = take(bootVolumeInfo()) else { throw failure() }
    guard let mounts = readKernelMounts() else {
        problems.append("the kernel mount table could not be read")
        throw failure()
    }

    let stores = containerStores(in: fullList)
    let boot = bootDisks(bootInfo: bootInfo, mounts: mounts, stores: stores)
    var images: [AttachedImage]? = includeImages ? readAttachedImages() : nil
    var askedHdiutil = includeImages
    let assembled = assembleDisks(
        physicalList: physicalList, wideList: wideList, fullList: fullList,
        bootDisks: boot,
        info: { diskutil(["info", "-plist", $0]) },
        roles: apfsRoles(ofVolume:),
        imageBackingPath: { device in
            images?.first { $0.wholeDisk == device }?.resolvedImagePath
        })
    problems += assembled.problems
    if assembled.timedOut { timedOut = true }
    guard problems.isEmpty else { throw failure(assembled.disks) }

    // Where each disk the cross-check cannot place comes from. On an ordinary
    // Mac every mount resolves to the startup disk or the enclosure before
    // this is asked, except disk images, which hdiutil names in one call.
    var origins: [String: DiskOrigin] = [:]
    func origin(of disk: String) -> DiskOrigin {
        if let known = origins[disk] { return known }
        if !askedHdiutil {
            images = readAttachedImages()
            askedHdiutil = true
        }
        let answer: DiskOrigin
        if images?.contains(where: { $0.wholeDisk == disk }) == true {
            answer = .diskImage
        } else if let info = diskutil(["info", "-plist", disk]).plist {
            if info["BusProtocol"] as? String == "Disk Image" {
                answer = .diskImage
            } else if info["Internal"] as? Bool == true {
                answer = .internalDisk
            } else {
                answer = .unknown
            }
        } else {
            answer = .unknown
        }
        origins[disk] = answer
        return answer
    }
    let attribution = MountAttribution(disks: assembled.disks, containerStores: stores,
                                       bootDisks: boot,
                                       hostsVirtualMembers: assembled.hostsVirtualMembers)
    return DiskSnapshot(disks: assembled.disks,
                        unaccountedMounts: unaccountedMounts(mounts, attribution: attribution,
                                                             origin: origin))
}

/// `diskutil info -plist /`, read once per process.
///
/// The startup disk cannot change while the system is running from it, and
/// the app reads disks every 30 seconds, so asking again would be a process
/// launch spent learning nothing. A failed read is not kept.
private enum BootInfoCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var value: [String: Any]?
}

func bootVolumeInfo() -> PlistRead {
    BootInfoCache.lock.lock()
    let cached = BootInfoCache.value
    BootInfoCache.lock.unlock()
    if let cached { return .plist(cached) }
    let read = diskutil(["info", "-plist", "/"])
    if let value = read.plist {
        BootInfoCache.lock.lock()
        BootInfoCache.value = value
        BootInfoCache.lock.unlock()
    }
    return read
}

/// Every APFS container in `diskutil list -plist`, mapped to the whole disks
/// of its physical stores.
func containerStores(in fullList: [String: Any]) -> [String: Set<String>] {
    var map: [String: Set<String>] = [:]
    for entry in fullList["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
        guard let device = entry["DeviceIdentifier"] as? String,
              let stores = entry["APFSPhysicalStores"] as? [[String: Any]] else { continue }
        map[device] = Set(stores.compactMap { $0["DeviceIdentifier"] as? String }
            .map(wholeDiskName(of:)))
    }
    return map
}

/// The disks the running system lives on, which DrivePark must never touch.
///
/// Until 2026-10-06 the only thing keeping the startup disk out was diskutil's
/// "external" flag (audit H3). On a Mac booted from an external SSD, Park
/// Tower and every automatic trigger would have tried to unmount the running
/// system's volumes, and an idle Update volume really can unmount. So the
/// disk behind / is excluded by name: its container, its physical stores, and
/// anything holding another of the system's mount points.
func bootDisks(bootInfo: [String: Any], mounts: [KernelMount],
               stores: [String: Set<String>]) -> Set<String> {
    var roots: Set<String> = []
    if let parent = bootInfo["ParentWholeDisk"] as? String { roots.insert(parent) }
    if let device = bootInfo["DeviceIdentifier"] as? String {
        roots.insert(wholeDiskName(of: device))
    }
    for store in bootInfo["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
        if let id = store["APFSPhysicalStore"] as? String { roots.insert(wholeDiskName(of: id)) }
    }
    for mount in mounts where isProtectedMountPoint(mount.mountPoint) {
        if let device = mount.bsdDevice { roots.insert(wholeDiskName(of: device)) }
    }
    var all = roots
    for root in roots { all.formUnion(underlyingDisks(of: root, stores: stores)) }
    return all
}

/// The APFS roles of a volume, read from IOKit in this process. Costs no
/// process launch and does not go through diskarbitrationd, so it cannot hang
/// on a stalled enclosure. `diskutil list -plist` carries no roles at all.
func apfsRoles(ofVolume bsdName: String) -> [String] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
    guard service != IO_OBJECT_NULL else { return [] }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(service, "Role" as CFString,
                                                    kCFAllocatorDefault, 0)?
        .takeRetainedValue() else { return [] }
    return raw as? [String] ?? []
}

struct AssembledDisks {
    var disks: [PhysicalDisk] = []
    /// Non-empty means the read is incomplete and nothing may be concluded
    /// from it.
    var problems: [String] = []
    var timedOut = false
    var hostsVirtualMembers = false
}

/// Builds the disk list from diskutil's answers. A pure function of its
/// inputs, so it is tested against captured plists rather than against
/// whatever is plugged into the Mac running the tests.
func assembleDisks(physicalList: [String: Any],
                   wideList: [String: Any]?,
                   fullList: [String: Any],
                   bootDisks: Set<String>,
                   info: (String) -> PlistRead,
                   roles: (String) -> [String],
                   imageBackingPath: (String) -> String?) -> AssembledDisks {
    var result = AssembledDisks()
    guard let physicalWhole = physicalList["WholeDisks"] as? [String] else {
        result.problems.append("diskutil list external physical answered without WholeDisks")
        return result
    }
    var externalSet = Set(physicalWhole).subtracting(bootDisks)
    var imageCandidates: Set<String> = []
    if let wideWhole = wideList?["WholeDisks"] as? [String] {
        imageCandidates = Set(wideWhole).subtracting(externalSet).subtracting(bootDisks)
        externalSet.formUnion(imageCandidates)
    } else if wideList != nil {
        result.problems.append("diskutil list external answered without WholeDisks")
        return result
    }

    guard let allEntries = fullList["AllDisksAndPartitions"] as? [[String: Any]] else {
        result.problems.append("diskutil list answered without AllDisksAndPartitions")
        return result
    }

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
        switch info(device) {
        case .plist(let details):
            disk.mediaName = details["MediaName"] as? String ?? "?"
            disk.busProtocol = details["BusProtocol"] as? String ?? "?"
            if let size = details["TotalSize"] as? Int64 { disk.sizeBytes = size }
            else if let size = details["TotalSize"] as? Int { disk.sizeBytes = Int64(size) }
            disk.removableMedia = details["RemovableMedia"] as? Bool
                ?? details["Removable"] as? Bool ?? false
            disk.ejectable = details["Ejectable"] as? Bool ?? false
        case .failed(let reason, let stalled):
            disk.infoAnswered = false
            if stalled { result.timedOut = true }
            // A candidate from the wide list that will not answer is dropped
            // below, as it always was. A physical disk that will not answer
            // stays in the list for display and makes the read incomplete.
            if !imageCandidates.contains(device) { result.problems.append(reason) }
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
    func volume(_ device: String, _ entry: [String: Any]) -> Volume? {
        let name = entry["VolumeName"] as? String
        let mountPoint = entry["MountPoint"] as? String
        guard name != nil || mountPoint != nil else { return nil }
        guard !isProtectedMountPoint(mountPoint) else { return nil }
        return Volume(device: device, name: name ?? "(unnamed)", mountPoint: mountPoint,
                      uuid: (entry["VolumeUUID"] as? String)?.lowercased())
    }

    for entry in allEntries {
        guard let entryDevice = entry["DeviceIdentifier"] as? String else { continue }

        if disks[entryDevice] != nil {
            let partitions = entry["Partitions"] as? [[String: Any]] ?? []
            // A filesystem written straight onto the whole disk, with no
            // partition table: an exFAT stick or an SD card formatted by a
            // camera. Captured 2026-10-06 from a partitionless exFAT image:
            // Content "", MountPoint and VolumeName on the whole-disk entry
            // itself, no Partitions key, no VolumeUUID. Before this it was
            // never listed, so it counted as unmounted (audit H2).
            if partitions.isEmpty, entry["APFSPhysicalStores"] == nil,
               let whole = volume(entryDevice, entry) {
                disks[entryDevice]?.directVolumes.append(whole)
            }
            // Direct (non-APFS) partitions on an external disk: exFAT, FAT32,
            // NTFS, HFS+, and similar mountable volumes.
            for partition in partitions {
                guard let partitionDevice = partition["DeviceIdentifier"] as? String
                else { continue }
                let content = partition["Content"] as? String ?? ""
                if virtualMemberContent.contains(content) { result.hostsVirtualMembers = true }
                guard !skippedContent.contains(content),
                      let found = volume(partitionDevice, partition) else { continue }
                disks[entryDevice]?.directVolumes.append(found)
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
        for volumeEntry in entry["APFSVolumes"] as? [[String: Any]] ?? [] {
            guard let volumeDevice = volumeEntry["DeviceIdentifier"] as? String else { continue }
            guard roles(volumeDevice).allSatisfy({ !systemVolumeRoles.contains($0) }) else { continue }
            let mountPoint = volumeEntry["MountPoint"] as? String
            guard !isProtectedMountPoint(mountPoint) else { continue }
            volumes.append(Volume(
                device: volumeDevice,
                name: volumeEntry["VolumeName"] as? String ?? "(unnamed)",
                mountPoint: mountPoint,
                uuid: (volumeEntry["VolumeUUID"] as? String)?.lowercased()))
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
    for device in imageCandidates {
        guard let disk = disks[device] else { continue }
        let points = disk.allVolumes.compactMap { $0.mountPoint }
        if isSystemManagedImage(backingPath: imageBackingPath(device), mountPoints: points) {
            disks[device] = nil
        }
    }
    result.disks = disks.keys.sorted().compactMap { disks[$0] }
    return result
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
