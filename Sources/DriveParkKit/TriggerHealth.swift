// TriggerHealth.swift — can this trigger actually fire?
//
// Every competitor lets you tick "park on sleep" and walk away believing it.
// On a Mac where something holds a power assertion, that box does nothing,
// forever, silently. Observed on mac-lan 2026-09-01: the Claude desktop app
// holds PreventUserIdleSystemSleep so remote sessions can reach the machine,
// pmset reports "sleep 0 (sleep prevented by powerd, Claude, configd)", and
// the sleep trigger can never run.
//
// A tool whose whole claim is that it reports reality instead of intent has to
// point that at its own settings too. An armed trigger that cannot fire is the
// same class of lie as an eject that did not eject.

import Foundation
import IOKit
import IOKit.pwr_mgt

public struct TriggerStatus {
    public let trigger: ParkTrigger
    public let canFire: Bool
    /// Present only when canFire is false. Written for a human, naming the
    /// process responsible where we can find it.
    public let reason: String?
}

/// Reads a pmset setting. Small, cached by the caller, and timeout-guarded
/// like every other subprocess in this codebase.
enum PowerSettings {
    /// Idle sleep timer in minutes. 0 means Never. nil means unreadable.
    static func idleSleepMinutes() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "drivepark.pmset", attributes: .concurrent)
        let box = TextBox()
        queue.async(group: group) {
            box.set(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        queue.async(group: group) { _ = err.fileHandleForReading.readDataToEndOfFile() }
        if group.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        for line in box.get().split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "sleep" else { continue }
            return Int(parts[1])
        }
        return nil
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
}

public enum PowerAssertions {
    /// System daemons whose assertions are normal and transient. powerd holds
    /// one the entire time your display is on; bluetoothd and sharingd come
    /// and go. Blaming these would fire the warning on every Mac in active
    /// use, and a warning that is always on is a warning nobody reads.
    static let routineDaemons: Set<String> = [
        "powerd", "configd", "bluetoothd", "sharingd", "WindowServer",
        "loginwindow", "coreaudiod", "kernel_task", "hidd"
    ]

    // Assertion type strings. Spelled out rather than imported because the
    // kIOPMAssertionType* constants do not all bridge into Swift. Verified
    // against live `pmset -g assertions` output on 2026-09-01.
    static let preventIdleSystemSleep = "PreventUserIdleSystemSleep"
    static let preventSystemSleep = "PreventSystemSleep"
    static let noIdleSleep = "NoIdleSleepAssertion"
    static let preventIdleDisplaySleep = "PreventUserIdleDisplaySleep"

    /// Process names currently holding any of the given assertion types.
    /// Deduplicated and sorted, so the menu reads the same way twice running.
    public static func holders(of types: Set<String>) -> [String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }

        var names: Set<String> = []
        for (_, value) in byProcess {
            guard let assertions = value as? [[String: Any]] else { continue }
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      types.contains(type) else { continue }
                let process = (assertion["Process Name"] as? String)
                    ?? (assertion["AssertName"] as? String)
                    ?? "an unnamed process"
                names.insert(process)
            }
        }
        return names.sorted()
    }
}

public enum TriggerHealth {
    /// Whether each trigger could fire right now, and why not when it cannot.
    ///
    /// Screen lock is always reachable: locking is a thing the user does, and
    /// nothing can hold it off the way an assertion holds off sleep.
    public static func status(for trigger: ParkTrigger) -> TriggerStatus {
        switch trigger {
        case .systemSleep:
            // Two separate causes, and they need different sentences. The
            // setting is durable; an app assertion is durable while that app
            // runs; a daemon assertion is neither and is filtered out.
            let holders = PowerAssertions.holders(of: [
                PowerAssertions.preventIdleSystemSleep,
                PowerAssertions.preventSystemSleep,
                PowerAssertions.noIdleSleep
            ]).filter { !PowerAssertions.routineDaemons.contains($0) }

            if PowerSettings.idleSleepMinutes() == 0 {
                var reason = "This Mac is set never to sleep on idle, so this will not fire."
                if !holders.isEmpty {
                    reason += " \(list(holders)) \(verb(holders)) holding sleep off."
                }
                return TriggerStatus(trigger: trigger, canFire: false, reason: reason)
            }
            if !holders.isEmpty {
                return TriggerStatus(
                    trigger: trigger, canFire: false,
                    reason: "\(list(holders)) \(verb(holders)) holding sleep off, so this "
                        + "will not fire while \(holders.count == 1 ? "it runs" : "they run").")
            }
            return TriggerStatus(trigger: trigger, canFire: true, reason: nil)

        case .displaySleep:
            let holders = PowerAssertions.holders(of: [PowerAssertions.preventIdleDisplaySleep])
                .filter { !PowerAssertions.routineDaemons.contains($0) }
            if holders.isEmpty {
                return TriggerStatus(trigger: trigger, canFire: true, reason: nil)
            }
            return TriggerStatus(
                trigger: trigger, canFire: false,
                reason: "The display is being kept awake by \(list(holders)). This will not fire.")

        case .screenLock:
            return TriggerStatus(trigger: trigger, canFire: true, reason: nil)
        }
    }

    public static func allStatuses() -> [TriggerStatus] {
        ParkTrigger.allCases.map(status(for:))
    }

    /// Armed triggers that cannot currently fire. The set worth warning about,
    /// because an unarmed trigger that cannot fire is nobody's problem.
    public static func armedButDead() -> [TriggerStatus] {
        allStatuses().filter { Preferences.isEnabled($0.trigger) && !$0.canFire }
    }

    /// Subject-verb agreement. "Claude and perplexityd is holding sleep off"
    /// is the kind of sentence that makes a careful reader trust the numbers
    /// less, which for this tool is expensive.
    private static func verb(_ names: [String]) -> String {
        names.count == 1 ? "is" : "are"
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "something"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
