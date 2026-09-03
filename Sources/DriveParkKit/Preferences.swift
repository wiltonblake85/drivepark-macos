// Preferences.swift — what DrivePark does on its own, and when.
//
// Everything here is off by default. A drive utility that starts unmounting
// volumes the moment it is installed has broken trust before it has earned it.

import Foundation

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
    private static let triggersKey = "enabledTriggers"
    private static let autoReleaseKey = "autoReleaseOnWake"
    private static let wakeDelayKey = "wakeReleaseDelay"

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

    /// Remount automatically once the machine wakes and the displays are back.
    public static var autoReleaseOnWake: Bool {
        get { store.bool(forKey: autoReleaseKey) }
        set { store.set(newValue, forKey: autoReleaseKey) }
    }

    /// Seconds to wait after wake before remounting. Docks and multi-bay
    /// bridges re-enumerate slowly; mounting into that window fails.
    public static var wakeReleaseDelay: TimeInterval {
        get {
            let stored = store.double(forKey: wakeDelayKey)
            return stored > 0 ? stored : 5
        }
        set { store.set(max(0, newValue), forKey: wakeDelayKey) }
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
    public static func recordDiagnostic(_ key: String, _ value: String) {
        store.set(value, forKey: "diag_\(key)")
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
    /// Refresh runs every 30 s, so anything past a couple of minutes is dead
    /// rather than briefly busy.
    public static let heartbeatStaleAfter: TimeInterval = 150

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
}
