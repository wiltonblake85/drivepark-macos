// TimeMachine.swift: which volumes Time Machine backs up to, and whether it
// is writing to one right now.
//
// Audit 2026-10-05, Low: a park silently stopped backups. Parking a Time
// Machine destination is a fine thing to do, but it should be said, and a
// backup in progress is the holder lsof cannot name: backupd runs as root, so
// a user-level lsof sees nothing, the park fails with no blocker, and the
// force prompt is left saying nobody is holding the volume.
//
// Read-only, through `tmutil -X` plists, with the same timeout and drained
// pipes as every other tool here.

import Foundation

public struct TimeMachineState: Equatable {
    /// Mount points of the configured destinations that are mounted.
    public var destinationMountPoints: Set<String> = []
    /// True while a backup runs, to any destination.
    public var backupRunning = false
    /// The mount point the running backup is writing to, when tmutil says.
    public var backingUpTo: String?

    public init(destinationMountPoints: Set<String> = [], backupRunning: Bool = false,
                backingUpTo: String? = nil) {
        self.destinationMountPoints = destinationMountPoints
        self.backupRunning = backupRunning
        self.backingUpTo = backingUpTo
    }

    /// Whether a running backup is writing to the volume mounted here. When
    /// tmutil names no destination for the running backup, every mounted
    /// destination counts: claiming a backup is elsewhere without knowing
    /// would be the kind of guess this tool does not make.
    public func isBackingUp(to mountPoint: String) -> Bool {
        guard backupRunning else { return false }
        if let backingUpTo { return backingUpTo == mountPoint }
        return destinationMountPoints.contains(mountPoint)
    }
}

/// Parses `tmutil destinationinfo -X` and `tmutil status -X`. A Mac with no
/// destination answers an empty dictionary, which parses to no destinations.
public func parseTimeMachine(destinationInfo: [String: Any],
                             status: [String: Any]?) -> TimeMachineState {
    var state = TimeMachineState()
    for destination in destinationInfo["Destinations"] as? [[String: Any]] ?? [] {
        if let point = destination["MountPoint"] as? String { state.destinationMountPoints.insert(point) }
    }
    if let status {
        state.backupRunning = (status["Running"] as? Bool)
            ?? ((status["Running"] as? Int).map { $0 != 0 } ?? false)
        state.backingUpTo = status["DestinationMountPoint"] as? String
    }
    return state
}

/// nil when tmutil did not answer, which is not the same as "no Time
/// Machine" and is not reported as if it were.
public func readTimeMachine(timeout: TimeInterval = 5) -> TimeMachineState? {
    guard let info = runPlistTool("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: timeout)
    else { return nil }
    let status = runPlistTool("/usr/bin/tmutil", ["status", "-X"], timeout: timeout)
    return parseTimeMachine(destinationInfo: info, status: status)
}
