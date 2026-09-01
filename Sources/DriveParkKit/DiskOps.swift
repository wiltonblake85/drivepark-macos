// DiskOps.swift — Disk Arbitration operations. Callbacks report what the
// request returned; truth about system state always comes from a fresh read.

import Foundation
import DiskArbitration

/// Converts an imported DA constant (e.g. kDAReturnBusy) to DAReturn safely.
func daReturn(_ value: Int) -> DAReturn {
    DAReturn(bitPattern: UInt32(truncatingIfNeeded: value))
}

struct OpResult {
    let success: Bool
    let detail: String?
    let busy: Bool
}

/// Volume UUIDs currently under park veto (read by the C approval callback).
var parkedVolumeUUIDs: Set<String> = []

final class DiskOps {
    private let queue = DispatchQueue(label: "park.diskops", qos: .userInitiated)
    private let session: DASession

    init?() {
        guard let created = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(created, queue)
        session = created
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
            let reason = (DADissenterGetStatusString(dissenter) as String?) ?? ""
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

    func unmount(volumeBSDName: String, force: Bool = false) -> OpResult {
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

    /// Registers a mount-approval veto for volumes in `parkedVolumeUUIDs`.
    func startMountVeto() {
        DARegisterDiskMountApprovalCallback(session, nil, { disk, _ -> Unmanaged<DADissenter>? in
            guard let description = DADiskCopyDescription(disk) as? [NSString: Any],
                  let rawUUID = description[kDADiskDescriptionVolumeUUIDKey] else { return nil }
            let cfValue = rawUUID as CFTypeRef
            guard CFGetTypeID(cfValue) == CFUUIDGetTypeID() else { return nil }
            let uuid = (CFUUIDCreateString(kCFAllocatorDefault, (cfValue as! CFUUID)) as String).lowercased()
            guard parkedVolumeUUIDs.contains(uuid) else { return nil }
            let name = (description[kDADiskDescriptionVolumeNameKey] as? String) ?? "volume"
            print("Vetoed remount of \"\(name)\" while parked.")
            let dissenter = DADissenterCreate(kCFAllocatorDefault, daReturn(kDAReturnExclusiveAccess), "Parked by DrivePark" as CFString)
            return Unmanaged.passRetained(dissenter)
        }, nil)
    }
}
