// RelaunchBudget.swift: how many times the watchdog brings a dying app back
// before it stops and says so.
//
// It used to back off for a minute after five restarts in a minute, and then
// start again, forever: an app that crashes on launch was relaunched five
// times a minute for as long as the Mac stayed up (audit, Low). Five deaths
// inside ten minutes is not something a restart fixes, so the watchdog now
// stops, records why, and waits for a person to start the app again.

import Foundation

public struct RelaunchBudget {
    public static let limit = 5
    public static let window: TimeInterval = 600

    private var deaths: [Date] = []
    /// True once the budget is spent. Stays true until `reset()`.
    public private(set) var exhausted = false

    public init() {}

    /// Notes that the app died, and answers whether to bring it back.
    public mutating func noteDeath(at now: Date) -> Bool {
        guard !exhausted else { return false }
        deaths = deaths.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if deaths.count >= Self.limit {
            exhausted = true
            return false
        }
        return true
    }

    /// A person started the app again, so whatever made it crash may be gone.
    public mutating func reset() {
        deaths = []
        exhausted = false
    }
}
