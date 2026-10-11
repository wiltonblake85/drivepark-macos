// DiskOps.swift: Disk Arbitration operations. Callbacks report what the
// request returned; truth about system state always comes from a fresh read.

import Foundation
import DiskArbitration

/// Converts an imported DA constant (e.g. kDAReturnBusy) to DAReturn safely.
func daReturn(_ value: Int) -> DAReturn {
    DAReturn(bitPattern: UInt32(truncatingIfNeeded: value))
}

public struct OpResult {
    public let success: Bool
    /// What macOS said when it refused, kept word for word. A dissenter's own
    /// string ("Parked by DrivePark", or whatever backupd says mid-backup) is
    /// sometimes the only clue to who is holding a volume when lsof sees
    /// nothing.
    public let detail: String?
    public let busy: Bool

    public init(success: Bool, detail: String? = nil, busy: Bool = false) {
        self.success = success
        self.detail = detail
        self.busy = busy
    }
}

/// Everything Engine reads about the disks. Behind a protocol so tests can
/// hand the engine a fresh read that fails on cue.
public protocol DiskDiscovering {
    /// A fresh read. Throws when any part of it failed or timed out.
    func discover() throws -> DiskSnapshot
    /// Attached disk images, or nil when hdiutil did not answer.
    func attachedImages() -> [AttachedImage]?
}

public struct SystemDiscovery: DiskDiscovering {
    public init() {}
    public func discover() throws -> DiskSnapshot { try discoverExternalDisks() }
    public func attachedImages() -> [AttachedImage]? { readAttachedImages() }
}

/// Everything Engine does to the disks.
public protocol DiskOperating: AnyObject {
    func unmount(volumeBSDName: String, force: Bool) -> OpResult
    func mount(volumeBSDName: String) -> OpResult
    func eject(diskBSDName: String) -> OpResult
    func isAttached(diskBSDName: String) -> Bool
    /// Whether this BSD name still holds this volume, asked of Disk
    /// Arbitration right before acting on it. Names are reused: a bay that
    /// renumbers between the read and the operation leaves the old name on a
    /// different volume, or on nothing.
    func identifies(_ volume: Volume, atBSDName bsdName: String) -> Bool
    /// The processes holding files open under a mount point.
    func blockers(mountPoint: String) -> [String]
    /// Makes the disk under a mount point spin up by reading from it past
    /// every cache, and waits at most `timeout` for the read. Never writes.
    func wake(mountPoint: String, timeout: TimeInterval) -> WakeResult
    /// Volume UUIDs whose remount is refused. Setting it changes the veto at
    /// once and publishes who holds it.
    var vetoedVolumeUUIDs: Set<String> { get set }
}

/// The veto set, read by the Disk Arbitration callback on its own queue and
/// written by the engine from whichever thread a park runs on. It used to be
/// a bare global with no lock.
final class VetoSet: @unchecked Sendable {
    private let lock = NSLock()
    private var uuids: Set<String> = []

    var value: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return uuids }
        set { lock.lock(); uuids = newValue; lock.unlock() }
    }

    func contains(_ uuid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return uuids.contains(uuid)
    }
}

final class DiskOps: DiskOperating {
    private let queue = DispatchQueue(label: "park.diskops", qos: .userInitiated)
    private let session: DASession
    private let veto = VetoSet()
    private var vetoRegistered = false

    init?() {
        guard let created = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(created, queue)
        session = created
    }

    deinit {
        if vetoRegistered {
            DAUnregisterCallback(
                session, unsafeBitCast(Self.approvalCallback, to: UnsafeMutableRawPointer.self),
                Unmanaged.passUnretained(veto).toOpaque())
        }
        DASessionSetDispatchQueue(session, nil)
    }

    private final class CallbackBox {
        let semaphore = DispatchSemaphore(value: 0)
        var result = OpResult(success: false, detail: "no response from Disk Arbitration", busy: false)
    }

    private static let operationCallback: @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void = { _, dissenter, context in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            // Written by whichever process dissented, so it is outside text.
            let reason = printable((DADissenterGetStatusString(dissenter) as String?) ?? "")
            let busy = UInt32(bitPattern: status) == UInt32(truncatingIfNeeded: kDAReturnBusy)
            let hex = String(UInt32(bitPattern: status), radix: 16)
            let detail = reason.isEmpty ? "DA status 0x\(hex)" : "\(reason) (0x\(hex))"
            box.result = OpResult(success: false, detail: detail, busy: busy)
        } else {
            box.result = OpResult(success: true, detail: nil, busy: false)
        }
        box.semaphore.signal()
    }

    private func disk(forBSDName bsdName: String) -> DADisk? {
        bsdName.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
    }

    private func perform(_ label: String, on bsdName: String, timeout: TimeInterval,
                         request: (DADisk, UnsafeMutableRawPointer) -> Void) -> OpResult {
        guard let disk = disk(forBSDName: bsdName) else {
            return OpResult(success: false, detail: "\(bsdName) not found", busy: false)
        }
        let box = CallbackBox()
        let context = Unmanaged.passRetained(box).toOpaque()
        request(disk, context)
        if box.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return OpResult(success: false, detail: "\(label) timed out after \(Int(timeout))s", busy: false)
        }
        return box.result
    }

    func unmount(volumeBSDName: String, force: Bool) -> OpResult {
        perform("unmount", on: volumeBSDName, timeout: 30) { disk, context in
            let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault)
            DADiskUnmount(disk, options, Self.operationCallback, context)
        }
    }

    func mount(volumeBSDName: String) -> OpResult {
        perform("mount", on: volumeBSDName, timeout: 30) { disk, context in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), Self.operationCallback, context)
        }
    }

    func eject(diskBSDName: String) -> OpResult {
        perform("eject", on: diskBSDName, timeout: 30) { disk, context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.operationCallback, context)
        }
    }

    func isAttached(diskBSDName: String) -> Bool {
        guard let disk = disk(forBSDName: diskBSDName),
              let description = DADiskCopyDescription(disk) as? [NSString: Any] else { return false }
        return !description.isEmpty
    }

    func identifies(_ volume: Volume, atBSDName bsdName: String) -> Bool {
        guard let disk = disk(forBSDName: bsdName),
              let description = DADiskCopyDescription(disk) as? [NSString: Any] else { return false }
        let uuid = Self.volumeUUID(in: description)
        if let expected = volume.uuid { return uuid == expected.lowercased() }
        // No UUID to go on. A UUID appearing means a different volume; a
        // different name, when there is one, means the same.
        guard uuid == nil else { return false }
        if let name = description[kDADiskDescriptionVolumeNameKey] as? String { return name == volume.name }
        return true
    }

    /// The volume UUID in a Disk Arbitration description, lowercased the way
    /// discovery stores it.
    static func volumeUUID(in description: [NSString: Any]) -> String? {
        guard let raw = description[kDADiskDescriptionVolumeUUIDKey] else { return nil }
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == CFUUIDGetTypeID() else { return nil }
        return (CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String).lowercased()
    }

    func blockers(mountPoint: String) -> [String] {
        lsofBlockers(mountPoint: mountPoint)
    }

    /// The read runs on its own thread and this waits for it with a timeout.
    /// During an enclosure stall (SPEC section 10, 2026-08-31) a read can sit
    /// in the kernel indefinitely; that thread is then left behind rather
    /// than letting it hang the park, the same rule lsof runs under.
    func wake(mountPoint: String, timeout: TimeInterval) -> WakeResult {
        let box = WakeBox()
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let read = uncachedProbeRead(under: mountPoint)
            box.finish(read ? .woke(seconds: Date().timeIntervalSince(started)) : .nothingToRead)
        }
        return box.wait(timeout: timeout) ?? .timedOut
    }

    var vetoedVolumeUUIDs: Set<String> {
        get { veto.value }
        set {
            veto.value = newValue
            // Say out loud who is holding it. The veto lives in this process's
            // memory and no other process can lift it, so a second process
            // needs to be able to find out that this one exists.
            VetoBroker.publishHold(newValue)
        }
    }

    private static let approvalCallback: DADiskMountApprovalCallback = { disk, context in
        guard let context,
              let description = DADiskCopyDescription(disk) as? [NSString: Any],
              let uuid = DiskOps.volumeUUID(in: description) else { return nil }
        let veto = Unmanaged<VetoSet>.fromOpaque(context).takeUnretainedValue()
        guard veto.contains(uuid) else { return nil }
        let name = (description[kDADiskDescriptionVolumeNameKey] as? String) ?? "volume"
        print("Vetoed remount of \"\(name)\" while parked.")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, daReturn(kDAReturnExclusiveAccess), "Parked by DrivePark" as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    /// Registers a mount-approval veto for the UUIDs in `vetoedVolumeUUIDs`.
    /// Inert while that set is empty.
    func startMountVeto() {
        guard !vetoRegistered else { return }
        DARegisterDiskMountApprovalCallback(session, nil, Self.approvalCallback,
                                            Unmanaged.passUnretained(veto).toOpaque())
        vetoRegistered = true
    }
}
