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
    private static let store = UserDefaults.standard
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
}
