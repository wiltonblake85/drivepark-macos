// DiskEvents.swift: Disk Arbitration's own word that a disk changed.
//
// The app used to learn about disks by reading them every 30 seconds: about
// six process launches a read, around 17,000 a day on an idle Mac, and a new
// mount could go unnoticed for half a minute (audit, Low). Disk Arbitration
// already knows the moment a disk appears, disappears, or a volume mounts,
// unmounts or is renamed, so the app now reads when it says so, and keeps a
// slow poll only as a backstop.
//
// An event is a reason to read, never a fact about the disks. What the menu
// shows still comes from a fresh read (SPEC section 7).

import Foundation
import DiskArbitration

public final class DiskEvents {
    private let queue = DispatchQueue(label: "drivepark.diskevents", qos: .utility)
    private let session: DASession
    private let settle: TimeInterval
    private var onChange: (() -> Void)?
    private var pending: DispatchWorkItem?
    private var registered = false

    /// - Parameter settle: how long to wait for the burst to finish. One park
    ///   of the tower is a dozen events; one read after the last is enough.
    public init?(settle: TimeInterval = 1.5) {
        guard let created = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = created
        self.settle = settle
        DASessionSetDispatchQueue(created, queue)
    }

    deinit {
        if registered {
            let context = Unmanaged.passUnretained(self).toOpaque()
            DAUnregisterCallback(session, unsafeBitCast(Self.diskCallback, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(Self.changedCallback, to: UnsafeMutableRawPointer.self), context)
        }
        DASessionSetDispatchQueue(session, nil)
    }

    /// Starts listening. `onChange` runs on a background queue, once per
    /// burst, after the disks have been quiet for `settle` seconds.
    ///
    /// Disk Arbitration answers the registration with an appeared event for
    /// every disk already attached, so the first call comes shortly after
    /// this one.
    public func start(_ onChange: @escaping () -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            guard !registered else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, Self.diskCallback, context)
            DARegisterDiskDisappearedCallback(session, nil, Self.diskCallback, context)
            let watched = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
            DARegisterDiskDescriptionChangedCallback(session, nil, watched, Self.changedCallback, context)
            registered = true
        }
    }

    private static let diskCallback: DADiskAppearedCallback = { _, context in
        guard let context else { return }
        Unmanaged<DiskEvents>.fromOpaque(context).takeUnretainedValue().noteChange()
    }

    private static let changedCallback: DADiskDescriptionChangedCallback = { _, _, context in
        guard let context else { return }
        Unmanaged<DiskEvents>.fromOpaque(context).takeUnretainedValue().noteChange()
    }

    /// On `queue`, where Disk Arbitration delivers.
    private func noteChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
