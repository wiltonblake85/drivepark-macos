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

public enum VetoBroker {
    /// Doorbell. Carries no payload, because the payload is in the store and a
    /// notification that arrives twice must not mean two mounts.
    public static let mountRequested = Notification.Name("com.wiltonblake.drivepark.mountRequested")

    private static var store: UserDefaults { Preferences.sharedStore }
    /// One record per holding process, under this prefix plus its pid.
    ///
    /// It was one shared record until 2026-10-06, and any process that armed
    /// a veto overwrote it: a `park now` from the CLI replaced the app's
    /// entry, and once the CLI exited nothing said the app was still holding
    /// (audit, Medium). With a key each, nobody writes over anybody.
    static let holderPrefix = "vetoHolder."
    // The shared record's keys, read once to carry a holder from an older
    // build across, then removed.
    private static let legacyPIDKey = "vetoHolderPID"
    private static let legacyNameKey = "vetoHolderName"
    private static let legacyUUIDsKey = "vetoHolderUUIDs"
    // Transient handshake keys: written, answered, and consumed inside a
    // minute, so renaming them (2026-09-07) needed no migration. The app and
    // the CLI ship from one package, so they never disagree on these names.
    private static let requestKey = "vetoMountRequest"
    private static let ackKey = "vetoMountAck"
    private static let answerKey = "vetoMountAnswer"

    public struct Holder: Equatable {
        public let pid: pid_t
        public let name: String
        public let uuids: Set<String>
        /// When the holding process started, seconds since 1970. With the pid
        /// it names one process for its whole life; a pid alone can be handed
        /// to a different process after the holder exits.
        public let started: Double?
        /// True for the menu bar app, which is the only holder that listens.
        /// A `park now --hold` in a terminal holds a real veto and answers
        /// nothing, so the CLI has to tell the user to go press Ctrl-C there.
        public var canAnswer: Bool { name == "DrivePark" }
    }

    // MARK: - Published by whoever holds the veto

    private static var ownKey: String { holderPrefix + String(ProcessInfo.processInfo.processIdentifier) }

    /// Called on every change to the veto set, including the change to empty.
    public static func publishHold(_ uuids: Set<String>) {
        guard !uuids.isEmpty else { return clearHold() }
        let pid = ProcessInfo.processInfo.processIdentifier
        var record: [String: Any] = ["name": ProcessInfo.processInfo.processName,
                                     "uuids": uuids.sorted()]
        if let started = processStartTime(pid) { record["started"] = started }
        store.set(record, forKey: ownKey)
    }

    /// Clears this process's record, and nobody else's.
    ///
    /// A park arms its veto before unmounting and drops it again if the park
    /// fails (audit H5). In the CLI that drop must not erase the app's record
    /// while the app still holds a real veto, or `park mount` would stop
    /// asking the app and run into its dissent instead.
    public static func clearHold() {
        store.removeObject(forKey: ownKey)
    }

    /// Every process holding a veto right now, the app first. Records left by
    /// a process that has exited are swept as they are found.
    ///
    /// The liveness check is the important half. A veto dies with the process
    /// that registered it, so a record left behind by a crash describes a hold
    /// that no longer exists, and acting on it would block a mount that would
    /// otherwise have worked. It used to be `kill(pid, 0)` alone, which a
    /// reused pid passes; the start time has to match as well.
    public static var holders: [Holder] {
        carryLegacyRecordAcross()
        var live: [Holder] = []
        for (key, value) in store.dictionaryRepresentation() where key.hasPrefix(holderPrefix) {
            if let holder = parseHolder(key: key, value: value),
               isAlive(holder, exists: processExists, startTime: processStartTime) {
                live.append(holder)
            } else {
                store.removeObject(forKey: key)
            }
        }
        return live.sorted { ($0.canAnswer ? 0 : 1, $0.pid) < ($1.canAnswer ? 0 : 1, $1.pid) }
    }

    /// The holder to talk to first: the app when it holds one.
    public static var holder: Holder? { holders.first }

    static func parseHolder(key: String, value: Any) -> Holder? {
        guard key.hasPrefix(holderPrefix),
              let pid = pid_t(key.dropFirst(holderPrefix.count)), pid > 0,
              let record = value as? [String: Any] else { return nil }
        return Holder(pid: pid,
                      name: record["name"] as? String ?? "unknown",
                      uuids: Set(record["uuids"] as? [String] ?? []),
                      started: record["started"] as? Double)
    }

    /// Alive means the pid exists and, when both start times are known, it is
    /// still the process that wrote the record. A second's slack covers the
    /// rounding between the two reads of the same clock.
    static func isAlive(_ holder: Holder, exists: (pid_t) -> Bool,
                        startTime: (pid_t) -> Double?) -> Bool {
        guard exists(holder.pid) else { return false }
        guard let recorded = holder.started, let now = startTime(holder.pid) else { return true }
        return abs(now - recorded) < 1
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func processStartTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    /// A holder recorded by a build before 2026-10-06, moved to its own key.
    private static func carryLegacyRecordAcross() {
        let pid = pid_t(store.integer(forKey: legacyPIDKey))
        guard pid > 0 else { return }
        store.set(["name": store.string(forKey: legacyNameKey) ?? "unknown",
                   "uuids": store.stringArray(forKey: legacyUUIDsKey) ?? []],
                  forKey: holderPrefix + String(pid))
        store.removeObject(forKey: legacyPIDKey)
        store.removeObject(forKey: legacyNameKey)
        store.removeObject(forKey: legacyUUIDsKey)
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
