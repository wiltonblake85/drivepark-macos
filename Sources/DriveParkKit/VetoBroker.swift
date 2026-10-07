// VetoBroker.swift — who is holding the remount veto, and how to ask them to
// drop it.
//
// Vocabulary: the action that remounts parked volumes is called Mount, in the
// menu, in the CLI (`park mount`), and in code. It was called Release until
// 2026-09-07; the history below keeps the old name where it quotes the past.
//
// The veto is a Disk Arbitration mount-approval callback registered on a
// DASession and gated by `vetoedVolumeUUIDs`. Both live in one process's
// memory, and that is not an implementation detail that can be factored away:
// DA dissent comes from the process that registered the callback, so no other
// process can lift it. `park mount` in a second process clears its own empty
// copy of the set and changes nothing.
//
// Which is the defect logged in SPEC section 10 on 2026-09-03. With the app
// holding a veto, `park release` (as it was then named) reported the app's own dissent string back to
// the user and stopped. It told the exact truth and offered no way out, which
// is half a product.
//
// So the holder publishes the fact that it is holding, and a mount becomes a
// message to the holder rather than an attempt to reach into its memory. The
// shared preferences suite carries the state and a distributed notification is
// the doorbell. Nothing here is trusted on its own: the requester confirms by
// reading the answer back, and a holder that never answers is reported as
// exactly that rather than papered over with a success message.

import Foundation

/// One process, told apart from any later process that reuses its pid.
struct ProcessIdentity: Equatable {
    /// When the process started, seconds since 1970 to the microsecond.
    let start: Double
    /// The kernel's short name for it (p_comm, at most MAXCOMLEN bytes).
    let name: String

    /// Read from the kernel with sysctl, which answers for any process,
    /// including root's, where kill(pid, 0) only says EPERM. nil when no
    /// process has this pid.
    static func of(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessIdentity(start: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000,
                               name: name)
    }
}

public enum VetoBroker {
    /// Doorbell. Carries no payload, because the payload is in the store and a
    /// notification that arrives twice must not mean two mounts.
    public static let mountRequested = Notification.Name("com.wiltonblake.drivepark.mountRequested")

    private static var store: UserDefaults { Preferences.sharedStore }
    private static let holderPIDKey = "vetoHolderPID"
    private static let holderNameKey = "vetoHolderName"
    private static let holderUUIDsKey = "vetoHolderUUIDs"
    private static let holderStartKey = "vetoHolderStart"
    // Transient handshake keys: written, answered, and consumed inside a
    // minute, so renaming them (2026-09-07) needed no migration. The app and
    // the CLI ship from one package, so they never disagree on these names.
    private static let requestKey = "vetoMountRequest"
    private static let ackKey = "vetoMountAck"
    private static let answerKey = "vetoMountAnswer"

    public struct Holder {
        public let pid: pid_t
        public let name: String
        public let uuids: Set<String>
        /// True for the menu bar app, which is the only holder that listens.
        /// A `park now --hold` in a terminal holds a real veto and answers
        /// nothing, so the CLI has to tell the user to go press Ctrl-C there.
        public var canAnswer: Bool { name == "DrivePark" }
    }

    // MARK: - Published by whoever holds the veto

    /// Called on every change to the veto set, including the change to empty.
    public static func publishHold(_ uuids: Set<String>) {
        guard !uuids.isEmpty else { return clearHold() }
        let pid = ProcessInfo.processInfo.processIdentifier
        store.set(Int(pid), forKey: holderPIDKey)
        store.set(ProcessInfo.processInfo.processName, forKey: holderNameKey)
        store.set(Array(uuids), forKey: holderUUIDsKey)
        if let start = ProcessIdentity.of(pid)?.start {
            store.set(start, forKey: holderStartKey)
        } else {
            store.removeObject(forKey: holderStartKey)
        }
    }

    /// Clears the record only when this process wrote it.
    ///
    /// A park now arms its veto before unmounting and drops it again if the
    /// park fails (audit H5). In the CLI that drop would otherwise erase the
    /// app's record while the app still holds a real veto, and `park mount`
    /// would stop asking the app and run into its dissent instead.
    public static func clearHold() {
        let recorded = pid_t(store.integer(forKey: holderPIDKey))
        guard recorded == 0 || recorded == ProcessInfo.processInfo.processIdentifier else { return }
        sweepHold()
    }

    private static func sweepHold() {
        store.removeObject(forKey: holderPIDKey)
        store.removeObject(forKey: holderNameKey)
        store.removeObject(forKey: holderUUIDsKey)
        store.removeObject(forKey: holderStartKey)
    }

    /// nil when nobody holds a veto, or when the recorded holder is gone.
    ///
    /// The liveness check is the important half. A veto dies with the process
    /// that registered it, so a record left behind by a crash describes a hold
    /// that no longer exists, and acting on it would block a mount that would
    /// otherwise have worked.
    public static var holder: Holder? {
        let pid = pid_t(store.integer(forKey: holderPIDKey))
        guard pid > 0 else { return nil }
        let name = store.string(forKey: holderNameKey) ?? "unknown"
        let start = store.object(forKey: holderStartKey) as? Double
        guard holderIsAlive(pid: pid, recordedStart: start, recordedName: name,
                            lookup: ProcessIdentity.of) else {
            sweepHold()
            return nil
        }
        let uuids = Set(store.stringArray(forKey: holderUUIDsKey) ?? [])
        return Holder(pid: pid, name: name, uuids: uuids)
    }

    /// Whether the process a holder record names is the one that wrote it.
    ///
    /// This used to be `kill(pid, 0)`, which answers a different question:
    /// is there any process with this number. pids are reused, so after a
    /// crash the record could name whatever started next, and a root-owned
    /// process answers EPERM, which was read as alive. Either way the stale
    /// veto never cleared and `park mount` waited on a holder that was gone
    /// (audit, Medium). A pid and its start time together name one process
    /// for the life of the machine.
    ///
    /// A record written before 2026-10-07 has no start time. For those the
    /// kernel's name for the process stands in: weaker, but a reused pid is
    /// rarely another DrivePark or another park.
    static func holderIsAlive(pid: pid_t, recordedStart: Double?, recordedName: String,
                              lookup: (pid_t) -> ProcessIdentity?) -> Bool {
        guard let running = lookup(pid) else { return false }
        if let recordedStart {
            return abs(running.start - recordedStart) < 0.000_5
        }
        return running.name == String(recordedName.prefix(Int(MAXCOMLEN)))
    }

    // MARK: - Asking the holder to mount

    /// - Returns: the nonce to wait on.
    public static func requestMount(disks: Set<String>?) -> String {
        let nonce = UUID().uuidString
        store.set(["nonce": nonce,
                   "disks": disks.map(Array.init) ?? [],
                   "scoped": disks != nil,
                   "at": Date().timeIntervalSince1970], forKey: requestKey)
        store.removeObject(forKey: answerKey)
        store.removeObject(forKey: ackKey)
        store.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            mountRequested, object: nil, userInfo: nil, deliverImmediately: true)
        return nonce
    }

    public struct Request {
        public let nonce: String
        public let disks: Set<String>?
    }

    /// Read by the holder. Requests older than a minute are stale: the CLI that
    /// asked has long since given up and told the user it timed out, and
    /// honouring it later would remount drives with nobody watching.
    public static func pendingRequest() -> Request? {
        guard let raw = store.dictionary(forKey: requestKey),
              let nonce = raw["nonce"] as? String,
              let at = raw["at"] as? Double,
              Date().timeIntervalSince1970 - at < 60 else { return nil }
        let scoped = (raw["scoped"] as? Bool) ?? false
        let disks = (raw["disks"] as? [String]).map(Set.init) ?? []
        return Request(nonce: nonce, disks: scoped ? disks : nil)
    }

    public static func consumeRequest() {
        store.removeObject(forKey: requestKey)
    }

    /// Written the instant the holder picks the request up, before it starts
    /// the work.
    ///
    /// Without this there is only one signal, and it has to answer two
    /// different questions: is anyone listening, and are they done yet.
    /// Conflating them produced a real wrong answer on 2026-09-04. A remount of
    /// three volumes took longer than the requester's fifteen second wait, so
    /// the CLI printed "DrivePark did not answer, the veto is still up" while
    /// the app was mid-remount, and the answer landed seconds later saying 3 of
    /// 3 mounted. Being early is not the same as being ignored, and a drive
    /// tool that confuses them tells the user the opposite of the truth.
    public static func acknowledge(nonce: String) {
        store.set(nonce, forKey: ackKey)
        store.synchronize()
    }

    public static func awaitAck(nonce: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            store.synchronize()
            if store.string(forKey: ackKey) == nonce { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    public enum Answer: Equatable {
        case mounted(Int, of: Int)
        /// The holder was in the middle of a park or a mount and did nothing.
        case busy
        /// The holder tried and could not verify what happened.
        case failed(String)
    }

    public static func answer(nonce: String, mounted: Int, total: Int) {
        store.set(["nonce": nonce, "mounted": mounted, "total": total],
                  forKey: answerKey)
        store.synchronize()
    }

    /// A request that lands during a park is declined out loud. It used to be
    /// run on top of the park and then clear the app's busy flag under it.
    public static func answerBusy(nonce: String) {
        store.set(["nonce": nonce, "busy": true], forKey: answerKey)
        store.synchronize()
    }

    public static func answerFailed(nonce: String, reason: String) {
        store.set(["nonce": nonce, "failure": reason], forKey: answerKey)
        store.synchronize()
    }

    /// Polls rather than blocking on the notification, because the requester is
    /// a short-lived CLI with no run loop and because a doorbell that does not
    /// ring must produce a timeout, not a hang.
    public static func awaitAnswer(nonce: String, timeout: TimeInterval) -> Answer? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            store.synchronize()
            if let raw = store.dictionary(forKey: answerKey),
               raw["nonce"] as? String == nonce {
                var answer: Answer?
                if raw["busy"] as? Bool == true {
                    answer = .busy
                } else if let failure = raw["failure"] as? String {
                    answer = .failed(failure)
                } else if let mounted = raw["mounted"] as? Int, let total = raw["total"] as? Int {
                    answer = .mounted(mounted, of: total)
                }
                if let answer {
                    store.removeObject(forKey: answerKey)
                    return answer
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }
}
