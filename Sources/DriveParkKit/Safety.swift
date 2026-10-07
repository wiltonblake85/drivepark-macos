// Safety.swift: the one answer this app exists to give, and what it is built
// from.
//
// "Safe to power off" means nothing on any discovered disk is mounted. Not
// nothing DrivePark manages: nothing. The ignore list decides what DrivePark
// is allowed to unmount; it has no say over whether pulling the cable loses
// data. Audit 2026-10-05, H1: with Plex ignored and streaming, the icon showed
// the checkmark and the CLI said every volume was verified unmounted.
//
// And not only what discovery lists. diskutil's view is assembled from
// partition tables and APFS containers, and a volume it does not know how to
// find (an exFAT stick with no partition table, a RAID set, a CoreStorage
// volume) used to count as unmounted because it was never counted at all
// (audit H2). The kernel's own mount table is the cross-check: anything it
// says is mounted on a discovered disk, or on a disk nobody can place, keeps
// the answer at no.

import Foundation

/// One entry from the kernel's mount table.
public struct KernelMount: Equatable, Sendable {
    /// f_mntfromname, e.g. "/dev/disk22s1".
    public let source: String
    public let mountPoint: String
    public let fileSystem: String

    public init(source: String, mountPoint: String, fileSystem: String = "") {
        self.source = source
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
    }

    /// The BSD device behind the mount, or nil when the source is not a disk
    /// (devfs, autofs, a network share). A mounted snapshot reads like
    /// "com.apple.TimeMachine.2026-10-06-090000.local@/dev/disk3s5", and it
    /// pins its volume just as surely, so the part after the last /dev/
    /// counts.
    public var bsdDevice: String? {
        var candidate = source
        if let range = source.range(of: "/dev/", options: .backwards) {
            candidate = String(source[range.upperBound...])
        }
        guard candidate.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil
        else { return nil }
        return candidate
    }
}

/// A mount the kernel reports that discovery cannot account for.
public struct UnaccountedMount: Equatable, Sendable {
    public enum Why: Equatable, Sendable {
        /// On a discovered disk, but not one of the volumes discovery listed
        /// as mounted there.
        case onDiscoveredDisk
        /// On a disk that is not internal, not the startup disk and not a disk
        /// image, so it could be on the enclosure and nothing here can say.
        case unattributed
    }

    public let device: String
    public let mountPoint: String
    public let why: Why

    public init(device: String, mountPoint: String, why: Why) {
        self.device = device
        self.mountPoint = mountPoint
        self.why = why
    }

    public var sentence: String {
        let point = printable(mountPoint)
        switch why {
        case .onDiscoveredDisk:
            return "\(point) (\(device)) is mounted on an external disk but discovery did not list it"
        case .unattributed:
            return "\(point) (\(device)) is mounted and DrivePark cannot tell which drive it lives on"
        }
    }
}

/// Whether the enclosure is safe to power off, from one fresh read.
public struct PowerOffVerdict {
    /// Every discovered volume still mounted, managed or ignored.
    public let mountedVolumes: [Volume]
    public let unaccountedMounts: [UnaccountedMount]

    public init(disks: [PhysicalDisk], unaccountedMounts: [UnaccountedMount]) {
        mountedVolumes = disks.flatMap { $0.allVolumes }.filter { $0.isMounted }
        self.unaccountedMounts = unaccountedMounts
    }

    /// The answer. Every surface that says "safe to power off", the icon, the
    /// status line, the notifications and the CLI, says it from this.
    public var safeToPowerOff: Bool { mountedVolumes.isEmpty && unaccountedMounts.isEmpty }

    /// What keeps it from being safe, or nil when it is.
    public func reason(isIgnored: (String?) -> Bool) -> String? {
        guard !safeToPowerOff else { return nil }
        var parts: [String] = []
        if !mountedVolumes.isEmpty {
            let names = mountedVolumes.map { volume -> String in
                isIgnored(volume.uuid) ? "\(volume.displayName) (on the ignore list)" : volume.displayName
            }
            parts.append("\(names.joined(separator: ", ")) still mounted")
        }
        parts.append(contentsOf: unaccountedMounts.map(\.sentence))
        return parts.joined(separator: "; ")
    }

    /// The same answer for a notch card: drive names, never a mount point,
    /// device or path. The card says what not to unplug; the menu and the CLI
    /// carry the rest.
    public var cardReason: String? {
        guard !safeToPowerOff else { return nil }
        var parts: [String] = []
        if !mountedVolumes.isEmpty {
            parts.append(mountedVolumes.map(\.displayName).joined(separator: ", ") + " still mounted")
        }
        if !unaccountedMounts.isEmpty {
            parts.append("\(unaccountedMounts.count) other mount(s) DrivePark cannot place")
        }
        return parts.joined(separator: "; ")
    }
}

/// Where a disk that is not on the enclosure comes from.
enum DiskOrigin {
    case internalDisk
    case diskImage
    case unknown
}

/// Everything the mount cross-check needs to know about the disks, gathered
/// by discovery and kept apart from it so the decision is a pure function.
struct MountAttribution {
    /// Each discovered physical disk and each APFS container on one.
    var discoveredWholeDisks: Set<String>
    /// BSD names of the discovered volumes the read says are mounted.
    var mountedVolumeDevices: Set<String>
    /// APFS container to the whole disks of its physical stores.
    var containerStores: [String: Set<String>]
    /// The disk the running system lives on, and its containers.
    var bootDisks: Set<String>
    /// True when a discovered disk carries a member of an AppleRAID set or a
    /// CoreStorage group. A virtual disk built from it could then be mounted
    /// under its own name, and "internal" stops being proof of anything.
    var hostsVirtualMembers: Bool

    init(disks: [PhysicalDisk], containerStores: [String: Set<String>],
         bootDisks: Set<String>, hostsVirtualMembers: Bool) {
        var whole = Set(disks.map(\.device))
        for disk in disks { whole.formUnion(disk.containers.map(\.device)) }
        discoveredWholeDisks = whole
        mountedVolumeDevices = Set(disks.flatMap { $0.allVolumes }
            .filter { $0.isMounted }.map(\.device))
        self.containerStores = containerStores
        self.bootDisks = bootDisks
        self.hostsVirtualMembers = hostsVirtualMembers
    }
}

/// The physical whole disks under `disk`, following APFS containers down to
/// their stores. A disk that is not a container is its own answer.
func underlyingDisks(of disk: String, stores: [String: Set<String>]) -> Set<String> {
    var result: Set<String> = []
    var queue = [disk]
    var seen: Set<String> = []
    while let next = queue.popLast() {
        guard seen.insert(next).inserted else { continue }
        if let parents = stores[next], !parents.isEmpty {
            queue.append(contentsOf: parents)
        } else {
            result.insert(next)
        }
    }
    return result
}

/// The kernel mounts discovery cannot account for.
///
/// `origin` is asked only about disks that are not on the enclosure and not
/// the startup disk, which on an ordinary Mac means only disk images.
func unaccountedMounts(_ mounts: [KernelMount], attribution: MountAttribution,
                       origin: (String) -> DiskOrigin) -> [UnaccountedMount] {
    var found: [UnaccountedMount] = []
    for mount in mounts {
        guard let device = mount.bsdDevice else { continue }
        let whole = wholeDiskName(of: device)
        let under = underlyingDisks(of: whole, stores: attribution.containerStores)
        let chain = under.union([whole])

        if !chain.isDisjoint(with: attribution.discoveredWholeDisks) {
            // Already counted when discovery listed it as mounted. Anything
            // else on these disks is mounted and was missed.
            if !attribution.mountedVolumeDevices.contains(device) {
                found.append(UnaccountedMount(device: device, mountPoint: mount.mountPoint,
                                              why: .onDiscoveredDisk))
            }
            continue
        }
        if !chain.isDisjoint(with: attribution.bootDisks) { continue }

        // A disk image is a file. If that file lives on the enclosure, the
        // volume holding it is mounted and already counted above.
        let origins = under.map(origin)
        if origins.contains(.diskImage) { continue }
        if !attribution.hostsVirtualMembers, !origins.isEmpty,
           origins.allSatisfy({ $0 == .internalDisk }) { continue }
        found.append(UnaccountedMount(device: device, mountPoint: mount.mountPoint,
                                      why: .unattributed))
    }
    return found
}

/// The kernel's mount table, or nil when it could not be read.
///
/// MNT_NOWAIT on purpose: MNT_WAIT refreshes every filesystem's statistics,
/// and a stalled enclosure is exactly the filesystem that will not answer.
/// The list of what is mounted does not need the refresh.
func readKernelMounts() -> [KernelMount]? {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else { return nil }
    // Room for a mount or two appearing between the two calls.
    let capacity = Int(count) + 8
    let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    let got = getfsstat(buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    guard got >= 0 else { return nil }
    return (0..<Int(got)).map { index in
        var entry = buffer[index]
        return KernelMount(source: cString(&entry.f_mntfromname),
                           mountPoint: cString(&entry.f_mntonname),
                           fileSystem: cString(&entry.f_fstypename))
    }
}

private func cString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
