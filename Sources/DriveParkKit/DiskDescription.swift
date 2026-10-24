// DiskDescription.swift: what discovery needs to know about a disk, without
// asking the disk.
//
// Measured 2026-10-24 on the tower: `diskutil info` on a drive that is spun
// down waits for it to spin up. Throw Away (disk9), parked and stopped by the
// courtesy spin-down, took 12.09, 12.13 and 12.28 s to answer it, whole disk
// or partition, past the 10 s every tool gets. One late answer made the whole
// read incomplete, so every park that started while it slept was refused,
// a park of a different drive included: "Could not read the disks before
// parking, so nothing was touched." It falls asleep again within about seven
// minutes of idle, so that was most parks, and the screen-lock trigger was
// refused four times that day.
//
// Disk Arbitration's description of the same sleeping disk answered in
// 0.001 s, and `diskutil info` 29 s later still waited out the full spin-up,
// so reading the description does not wake the drive. It is diskarbitrationd's
// own record of the disk, built from the IORegistry when the disk appeared.
// Nothing is sent to the drive.
//
// What this gives up: on 2026-08-31 the bridge stopped answering `diskutil
// info` on every bay while `diskutil list` kept working, and the 10 s limit
// on that call is what said so. A description cannot see a stalled bridge.
// The verdict never rested on it: what is mounted comes from `diskutil list`
// and the kernel's mount table. A stall still shows where it costs something,
// in the wake read and the unmount, which have limits of their own.

import DiskArbitration
import Foundation

/// The keys `assembleDisks` reads, under diskutil's names, taken from a Disk
/// Arbitration description. Pure, so the mapping is tested against captured
/// descriptions.
///
/// Captured 2026-10-24, diskutil against Disk Arbitration on the same disks
/// (the tower's four bays, two of their volumes, the internal SSD and a
/// simulator image):
/// - MediaName is DADeviceModel: "TDAS". DAMediaName is "TerraMas TDAS Media".
/// - BusProtocol is DADeviceProtocol ("USB", "Apple Fabric"), except for a
///   disk image, which Disk Arbitration describes as "Virtual Interface" with
///   the model "Disk Image" and diskutil calls "Disk Image". Discovery admits
///   image candidates on that word.
/// - TotalSize, RemovableMedia and VolumeUUID match.
/// - Internal is absent for a disk image, which diskutil reports as false.
/// - Ejectable differs: diskutil said true for the bays, Disk Arbitration
///   says false, the IOMedia flag. Nothing reads it.
func diskutilShapedInfo(_ description: [String: Any]) -> [String: Any] {
    var info: [String: Any] = [:]
    let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
    if let model { info["MediaName"] = model }
    if let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String {
        info["BusProtocol"] = (deviceProtocol == "Virtual Interface" && model == "Disk Image")
            ? "Disk Image" : deviceProtocol
    }
    if let size = description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber {
        info["TotalSize"] = size.int64Value
    }
    if let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool {
        info["RemovableMedia"] = removable
    }
    if let ejectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool {
        info["Ejectable"] = ejectable
    }
    info["Internal"] = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
    if let raw = description[kDADiskDescriptionVolumeUUIDKey as String] {
        let object = raw as AnyObject
        if CFGetTypeID(object) == CFUUIDGetTypeID(),
           let text = CFUUIDCreateString(kCFAllocatorDefault, unsafeBitCast(object, to: CFUUID.self)) {
            info["VolumeUUID"] = text as String
        } else if let text = raw as? String {
            info["VolumeUUID"] = text
        }
    }
    return info
}

/// One disk's details, under diskutil's key names, with no process launched
/// and nothing sent to the drive.
///
/// Asked on a worker thread with a limit, like every tool DrivePark runs.
/// diskarbitrationd answers from memory, so this has never come near the
/// limit; if it ever stops answering, the read says so instead of hanging its
/// caller. A call past the limit leaves its worker waiting on
/// diskarbitrationd, and by then every Disk Arbitration operation is waiting
/// with it.
func describeDisk(_ bsdName: String, timeout: TimeInterval = 5) -> PlistRead {
    let box = DescriptionBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
            box.set(DADiskCopyDescription(disk) as? [String: Any])
        }
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        return .failed(reason: "Disk Arbitration did not describe \(bsdName) in \(Int(timeout))s",
                       timedOut: true)
    }
    guard let description = box.get(), !description.isEmpty else {
        return .failed(reason: "Disk Arbitration has no \(bsdName); it may have been unplugged",
                       timedOut: false)
    }
    return .plist(diskutilShapedInfo(description))
}

private final class DescriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?
    func set(_ new: [String: Any]?) { lock.lock(); value = new; lock.unlock() }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
}
