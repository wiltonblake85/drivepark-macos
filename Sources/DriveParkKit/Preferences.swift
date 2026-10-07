// Preferences.swift — what DrivePark does on its own, and when.
//
// Everything here is off by default. A drive utility that starts unmounting
// volumes the moment it is installed has broken trust before it has earned it.

import Foundation
import Security

/// An event that can cause an automatic park.
public enum ParkTrigger: String, CaseIterable, Sendable {
    /// The machine is going to sleep. Carries a hard deadline: macOS waits
    /// roughly 30 s for acknowledgement, then sleeps regardless.
    case systemSleep
    /// The displays turned off while the machine stayed awake.
    case displaySleep
    /// The screen was locked.
    case screenLock

    public var label: String {
        switch self {
        case .systemSleep: return "Park when the Mac sleeps"
        case .displaySleep: return "Park when the displays turn off"
        case .screenLock: return "Park when the screen locks"
        }
    }
}

public enum Preferences {
    /// One preferences domain for the app AND the CLI.
    ///
    /// `UserDefaults.standard` resolves per process: the bundled app gets
    /// com.wiltonblake.drivepark, the CLI gets a domain named after its own
    /// executable. Proven on 2026-09-01, when `park ignore T7` wrote to a
    /// domain called "park", the app never saw it, and the CLI still printed
    /// "DrivePark will not unmount it." A false assurance about a drive
    /// mid-copy is the worst bug this project can ship.
    ///
    /// suiteName returns nil when it matches the running app's own bundle id,
    /// which is exactly when `.standard` is already the right store, so the
    /// fallback lands both processes in the same place.
    public static let domain = "com.wiltonblake.drivepark"
    private static let store = UserDefaults(suiteName: domain) ?? .standard

    /// Raw access to the one store, for the few collaborators that need to
    /// read and write keys this file does not model. VetoBroker is the only
    /// one today. Everything else goes through the typed accessors below,
    /// because the whole point of the paragraph above is that there is
    /// exactly one store and nobody re-derives it.
    public static var sharedStore: UserDefaults { store }
    private static let triggersKey = "enabledTriggers"
    private static let autoMountKey = "autoMountOnWake"
    private static let wakeDelayKey = "wakeMountDelay"

    /// One-time carry-over from the names these settings had before the
    /// Release-to-Mount rename on 2026-09-07. A rename that silently turns
    /// auto-mount off for anyone who had it on is a regression wearing a
    /// vocabulary change as a disguise. Runs on first read of either key,
    /// copies what it finds, then removes the old keys so it cannot run twice.
    private static let legacyAutoMountKey = "autoReleaseOnWake"
    private static let legacyWakeDelayKey = "wakeReleaseDelay"
    private static let wakeKeysMigrated: Void = {
        if store.object(forKey: legacyAutoMountKey) != nil {
            if store.object(forKey: autoMountKey) == nil {
                store.set(store.bool(forKey: legacyAutoMountKey), forKey: autoMountKey)
            }
            store.removeObject(forKey: legacyAutoMountKey)
        }
        if store.object(forKey: legacyWakeDelayKey) != nil {
            if store.object(forKey: wakeDelayKey) == nil {
                store.set(store.double(forKey: legacyWakeDelayKey), forKey: wakeDelayKey)
            }
            store.removeObject(forKey: legacyWakeDelayKey)
        }
    }()

    /// Triggers currently armed. Empty by default: DrivePark parks on its own
    /// only after the user has said so.
    public static var enabledTriggers: Set<ParkTrigger> {
        get {
            guard let raw = store.array(forKey: triggersKey) as? [String] else { return [] }
            return Set(raw.compactMap(ParkTrigger.init(rawValue:)))
        }
        set { store.set(newValue.map(\.rawValue).sorted(), forKey: triggersKey) }
    }

    public static func isEnabled(_ trigger: ParkTrigger) -> Bool {
        enabledTriggers.contains(trigger)
    }

    public static func setEnabled(_ trigger: ParkTrigger, _ on: Bool) {
        var current = enabledTriggers
        if on { current.insert(trigger) } else { current.remove(trigger) }
        enabledTriggers = current
    }

    /// Mount automatically once the machine wakes and the displays are back.
    public static var autoMountOnWake: Bool {
        get { _ = wakeKeysMigrated; return store.bool(forKey: autoMountKey) }
        set { _ = wakeKeysMigrated; store.set(newValue, forKey: autoMountKey) }
    }

    /// Seconds to wait after wake before mounting. Docks and multi-bay
    /// bridges re-enumerate slowly; mounting into that window fails.
    public static var wakeMountDelay: TimeInterval {
        get {
            _ = wakeKeysMigrated
            let stored = store.double(forKey: wakeDelayKey)
            return stored > 0 ? stored : 5
        }
        set { _ = wakeKeysMigrated; store.set(max(0, newValue), forKey: wakeDelayKey) }
    }

    /// How long a sleep-triggered park may take before DrivePark stops asking
    /// for more time. macOS allows roughly 30 s; stopping at 20 leaves room to
    /// verify and report before the machine goes down.
    public static let sleepParkBudget: TimeInterval = 20

    /// Diagnostics the app records about itself, readable with
    /// `defaults read com.wiltonblake.drivepark`.
    ///
    /// Goes through `store` on purpose. Re-deriving the store with
    /// UserDefaults(suiteName:) returns nil inside the app, because the name
    /// is its own bundle id, and every write then vanishes without error.
    /// That mistake has now been made twice in one day, so there is exactly
    /// one store and this is the only way to write to it.
    ///
    /// Written only when the value changes. Several of these are recorded on
    /// every refresh or every watchdog tick with the same answer each time,
    /// and every write is cfprefsd rewriting the domain on disk (audit, Low).
    public static func recordDiagnostic(_ key: String, _ value: String) {
        let full = "diag_\(key)"
        guard store.string(forKey: full) != value else { return }
        store.set(value, forKey: full)
    }

    // MARK: - The global shortcut
    //
    // Stored as the raw key code plus Carbon modifier mask, because that is
    // what RegisterEventHotKey takes, plus a display string captured at
    // recording time. The display string is stored rather than derived: going
    // from a key code back to a printed character means asking the current
    // keyboard layout, and a shortcut recorded on one layout should still read
    // correctly after the user switches to another.

    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let hotKeyDisplayKey = "hotKeyDisplay"

    /// kVK_ANSI_P. Four-finger default, chosen to be hard to hit by accident.
    public static let defaultHotKeyCode: UInt32 = 35
    /// controlKey | optionKey | cmdKey
    public static let defaultHotKeyModifiers: UInt32 = 4096 | 2048 | 256
    public static let defaultHotKeyDisplay = "⌃⌥⌘P"

    public static var hotKeyCode: UInt32 {
        get {
            let stored = store.object(forKey: hotKeyCodeKey) as? Int
            return stored.map(UInt32.init) ?? defaultHotKeyCode
        }
        set { store.set(Int(newValue), forKey: hotKeyCodeKey) }
    }

    public static var hotKeyModifiers: UInt32 {
        get {
            let stored = store.object(forKey: hotKeyModifiersKey) as? Int
            return stored.map(UInt32.init) ?? defaultHotKeyModifiers
        }
        set { store.set(Int(newValue), forKey: hotKeyModifiersKey) }
    }

    public static var hotKeyDisplay: String {
        get { store.string(forKey: hotKeyDisplayKey) ?? defaultHotKeyDisplay }
        set { store.set(newValue, forKey: hotKeyDisplayKey) }
    }

    public static func resetHotKeyToDefault() {
        hotKeyCode = defaultHotKeyCode
        hotKeyModifiers = defaultHotKeyModifiers
        hotKeyDisplay = defaultHotKeyDisplay
    }

    // MARK: - Heartbeat
    //
    // The app writes the time on every refresh. Anything else can then tell
    // "running" from "gone" without asking the process table, which matters
    // because every automatic park depends on the app being alive and nothing
    // used to say whether it was.

    private static let heartbeatKey = "lastHeartbeat"
    /// The backstop read runs every 5 minutes (it was every 30 s until
    /// 2026-10-07), so anything past two of those is dead rather than briefly
    /// busy.
    public static let heartbeatStaleAfter: TimeInterval = 660

    public static func recordHeartbeat() {
        store.set(Date().timeIntervalSince1970, forKey: heartbeatKey)
    }

    public static var lastHeartbeat: Date? {
        let stamp = store.double(forKey: heartbeatKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// nil when the app has never run. Otherwise how long since it checked in.
    public static var heartbeatAge: TimeInterval? {
        lastHeartbeat.map { Date().timeIntervalSince($0) }
    }

    public static var appLooksAlive: Bool {
        guard let age = heartbeatAge else { return false }
        return age < heartbeatStaleAfter
    }

    /// Global shortcut on or off. Default on: a hotkey nobody knows about is
    /// the same as no hotkey, and the menu shows the combination next to the
    /// action so it is discoverable rather than folklore.
    private static let hotKeyKey = "hotKeyEnabled"
    public static var hotKeyEnabled: Bool {
        get { store.object(forKey: hotKeyKey) as? Bool ?? true }
        set { store.set(newValue, forKey: hotKeyKey) }
    }

    // MARK: - The manage list

    /// Whether mounted disk images count as parkable drives. Off by default,
    /// because the answer to "is it safe to unplug the enclosure" should not
    /// change because a .dmg happens to be open.
    private static let includeImagesKey = "includeDiskImages"
    public static var includeDiskImages: Bool {
        get { store.bool(forKey: includeImagesKey) }
        set { store.set(newValue, forKey: includeImagesKey) }
    }

    /// The volumes automatic parks took down, by UUID, waiting for the wake
    /// that undoes them.
    ///
    /// Persisted, because it decides what the next wake remounts, and it used
    /// to live only in a TriggerCoordinator field. Any restart between the
    /// park and the wake reset it, and the wake then declined to remount and
    /// said nothing: the drives stayed parked and the user was left to work
    /// out why. Watched happen on 2026-09-04, when a rebuild landed between a
    /// screen-lock park and the unlock. A restart in that window is not
    /// exotic. The watchdog relaunches after a crash, and an update replaces
    /// the app, and both are exactly the moments where quietly forgetting to
    /// remount is worst.
    ///
    /// A set of volumes rather than a yes or no since 2026-10-06. The flag
    /// said only that a trigger had parked, so the wake mounted everything and
    /// dropped the whole veto, and a drive parked by hand came back with the
    /// rest. Parking or mounting by hand takes volumes out of this set.
    private static let triggerParkedKey = "triggerParkedVolumeUUIDs"
    public static var triggerParkedVolumeUUIDs: Set<String> {
        get { Set(store.stringArray(forKey: triggerParkedKey) ?? []) }
        set {
            if newValue.isEmpty {
                store.removeObject(forKey: triggerParkedKey)
            } else {
                store.set(newValue.sorted(), forKey: triggerParkedKey)
            }
        }
    }

    /// The old flag, from builds before 2026-10-06. Still read once: a trigger
    /// park made by an old build and woken under a new one would otherwise be
    /// left parked, which is the 2026-09-04 failure over again. It names no
    /// volumes, so that one wake mounts everything, as it always did.
    private static let parkedByTriggerKey = "parkedByTrigger"
    public static var legacyParkedByTrigger: Bool {
        get { store.bool(forKey: parkedByTriggerKey) }
        set {
            if newValue {
                store.set(true, forKey: parkedByTriggerKey)
            } else {
                store.removeObject(forKey: parkedByTriggerKey)
            }
        }
    }

    private static let ignoredKey = "ignoredVolumeUUIDs"

    /// Volumes DrivePark leaves alone. Nothing automatic touches them, and
    /// neither does Park Tower. Only naming that drive's own button does.
    ///
    /// Keyed on volume UUID because whole disks in a multi-bay enclosure are
    /// not distinguishable: identical media name, identical device-tree path,
    /// and sometimes identical size.
    ///
    /// This exists because the drive you must never unmount is usually the one
    /// in use. A media server library mid-stream, an external SSD mid-copy.
    public static var ignoredVolumeUUIDs: Set<String> {
        get { Set(store.stringArray(forKey: ignoredKey) ?? []) }
        set { store.set(newValue.sorted(), forKey: ignoredKey) }
    }

    public static func isIgnored(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        return ignoredVolumeUUIDs.contains(uuid.lowercased())
    }

    public static func setIgnored(_ uuid: String, _ on: Bool) {
        var current = ignoredVolumeUUIDs
        if on { current.insert(uuid.lowercased()) } else { current.remove(uuid.lowercased()) }
        ignoredVolumeUUIDs = current
    }

    // MARK: - Transom, the notch channel
    //
    // macOS refuses this app's notification banners at registration, so the
    // card in the notch is the only visual signal that works here.
    //
    // Off by default since 2026-10-07 (audit, Low). It was on, and with no
    // token every card went out as a transom:// link, which any installed app
    // can register to receive, carrying volume and process names. A channel
    // that sends what is on your drives to whoever claims a URL scheme is one
    // a person should switch on knowingly.

    private static let transomEnabledKey = "transomEnabled"
    private static let legacyTransomTokenKey = "transomToken"
    private static let transomTokenAccount = "transom-token"

    /// Existing installs keep what they chose. An explicit on or off is left
    /// alone. An install that never touched the switch but saved a token was
    /// using the cards, so it stays on; one that did neither gets the new
    /// default. Runs once, on the first read.
    private static let transomDefaultMigrated: Void = {
        guard store.object(forKey: transomEnabledKey) == nil else { return }
        let hadToken = !(store.string(forKey: legacyTransomTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hadToken { store.set(true, forKey: transomEnabledKey) }
    }()

    public static var transomEnabled: Bool {
        get { _ = transomDefaultMigrated; return store.object(forKey: transomEnabledKey) as? Bool ?? false }
        set { _ = transomDefaultMigrated; store.set(newValue, forKey: transomEnabledKey) }
    }

    /// The token for Transom's loopback API, from DrivePark's own Keychain
    /// item. It lived in plain text in this preferences domain until
    /// 2026-10-07; a token found there is moved into the Keychain on the first
    /// read, and removed from preferences only once the Keychain has it.
    public static var transomToken: String? {
        if let legacy = store.string(forKey: legacyTransomTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            guard saveTransomToken(legacy) else { return legacy }
        }
        let stored = Keychain.read(account: transomTokenAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    /// Moves a token left in preferences by an older build into the Keychain
    /// now, rather than on the first card, which can be days away. Called at
    /// launch.
    public static func moveTransomTokenToKeychain() {
        _ = transomToken
    }

    /// Stores the token in the Keychain, or removes it for nil or empty.
    /// - Returns: false when the Keychain refused, so the caller can say so
    ///   instead of reporting a token saved that was not.
    @discardableResult
    public static func saveTransomToken(_ token: String?) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let saved: Bool
        if trimmed.isEmpty {
            saved = Keychain.delete(account: transomTokenAccount)
        } else {
            let status = Keychain.write(trimmed, account: transomTokenAccount,
                                        label: "DrivePark: Transom token")
            saved = status == errSecSuccess
            if !saved { recordDiagnostic("transomTokenSave", "Keychain refused, OSStatus \(status)") }
        }
        if saved { store.removeObject(forKey: legacyTransomTokenKey) }
        return saved
    }
}


// MARK: - The watchdog handshake
//
// Three pieces of state shared by the app, the watchdog and build-app.sh. They
// live in this file rather than in the watchdog because all three processes
// have to agree on them, and this file is the one place that guarantees they
// are reading the same store. The 2026-09-01 bug where the CLI wrote to a
// domain called "park" and the app never saw it is the reason that guarantee
// is worth keeping in one place.

extension Preferences {
    private static let quitRequestedKey = "quitRequestedAt"
    private static let watchdogPausedKey = "watchdogPausedUntil"
    private static let watchdogHeartbeatKey = "watchdogHeartbeat"

    /// A quit is honoured for ten seconds. Long enough to cover the app
    /// actually going away, short enough that a stamp left behind by a crash
    /// during shutdown cannot suppress a real rescue tomorrow.
    public static let quitRequestHonoured: TimeInterval = 10

    /// Called on the way out of a deliberate Quit, and nowhere else.
    public static func noteQuitRequested() {
        store.set(Date().timeIntervalSince1970, forKey: quitRequestedKey)
        // Deprecated, and right here. The process is about to terminate and
        // the watchdog reads this within milliseconds. The usual background
        // flush does not reliably win that race.
        store.synchronize()
    }

    public static var quitWasRequested: Bool {
        let stamp = store.double(forKey: quitRequestedKey)
        guard stamp > 0 else { return false }
        return Date().timeIntervalSince1970 - stamp < quitRequestHonoured
    }

    public static func clearQuitRequest() {
        store.removeObject(forKey: quitRequestedKey)
    }

    /// Set by build-app.sh while the bundle is being replaced, because the
    /// watchdog would otherwise relaunch the app into a half-written bundle,
    /// which is exactly how the app vanished with no crash report on
    /// 2026-09-01. Written from the shell as a bare epoch, so it stays a
    /// Double rather than a Date.
    public static var watchdogPausedUntil: Date? {
        get {
            let stamp = store.double(forKey: watchdogPausedKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            if let newValue {
                store.set(newValue.timeIntervalSince1970, forKey: watchdogPausedKey)
            } else {
                store.removeObject(forKey: watchdogPausedKey)
            }
        }
    }

    /// The watchdog writes its heartbeat at most once a minute, so two and a
    /// half minutes of silence is dead rather than briefly busy.
    public static let watchdogStaleAfter: TimeInterval = 150
    public static let watchdogHeartbeatEvery: TimeInterval = 60

    /// Written at most once a minute. It was written on every 5 s tick, which
    /// was a preferences write every 5 s, forever, on a Mac doing nothing
    /// (audit, Low).
    public static func recordWatchdogHeartbeat() {
        let now = Date().timeIntervalSince1970
        let last = store.double(forKey: watchdogHeartbeatKey)
        guard now - last >= watchdogHeartbeatEvery || now < last else { return }
        store.set(now, forKey: watchdogHeartbeatKey)
    }

    private static let watchdogGaveUpKey = "watchdogGaveUpAt"

    /// Set when the watchdog stopped restarting a crashing app, read and
    /// cleared by the app the next time a person starts it, so that the
    /// stop is said out loud once rather than only noticed as a gap in the
    /// menu bar.
    public static var watchdogGaveUpAt: Date? {
        get {
            let stamp = store.double(forKey: watchdogGaveUpKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            if let newValue {
                store.set(newValue.timeIntervalSince1970, forKey: watchdogGaveUpKey)
            } else {
                store.removeObject(forKey: watchdogGaveUpKey)
            }
        }
    }

    /// What the menu reads to decide whether "on" is telling the truth.
    public static var watchdogLooksAlive: Bool {
        let stamp = store.double(forKey: watchdogHeartbeatKey)
        guard stamp > 0 else { return false }
        return Date().timeIntervalSince1970 - stamp < watchdogStaleAfter
    }
}

extension Preferences {
    private static let agentFingerprintKey = "registeredAgentFingerprint"
    private static let agentPendingKey = "agentReRegisterPending"

    /// The digest of the agent plist as it stood when launchd was last given
    /// it. launchd keeps the definition it was handed at registration, so a
    /// plist edited in the bundle changes nothing until the service is
    /// registered again, and a kickstart in the meantime runs the old one.
    public static var registeredAgentFingerprint: String? {
        get { store.string(forKey: agentFingerprintKey) }
        set {
            if let newValue {
                store.set(newValue, forKey: agentFingerprintKey)
            } else {
                store.removeObject(forKey: agentFingerprintKey)
            }
        }
    }

    /// Set across the unregister-then-register pair, because on the version
    /// being migrated away from the unregister can kill this process before
    /// the register runs. The next launch reads this and finishes the job.
    public static var agentReRegisterPending: Bool {
        get { store.bool(forKey: agentPendingKey) }
        set { store.set(newValue, forKey: agentPendingKey); store.synchronize() }
    }
}
