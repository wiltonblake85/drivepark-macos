// TimeMachine.swift: a park must not quietly stop a backup.
//
// Unmounting a Time Machine destination in the middle of a backup ends the
// backup, and until 2026-10-07 nothing here knew a destination from any other
// volume (audit, Low). Now a park asks Time Machine first. An automatic park
// onto a backup in progress is refused; a park a person asked for comes back
// refused with the volumes named, so the menu or the CLI can ask them, and
// runs only once they say yes.
//
// Read with tmutil, which is the one public interface. It runs once per park,
// never on a refresh, so it adds nothing to the idle cost.

import Foundation

/// What Time Machine says it is doing.
public struct BackupStatus: Equatable {
    public var running: Bool
    /// Mount points of the destinations Time Machine has configured and
    /// mounted. Read only while a backup is running.
    public var destinationMountPoints: Set<String>
    /// The mount point of the destination the running backup writes to, when
    /// Time Machine says which.
    public var activeMountPoint: String?

    public init(running: Bool, destinationMountPoints: Set<String> = [],
                activeMountPoint: String? = nil) {
        self.running = running
        self.destinationMountPoints = destinationMountPoints
        self.activeMountPoint = activeMountPoint
    }
}

public protocol BackupReading {
    /// nil when Time Machine did not answer.
    func backupStatus() -> BackupStatus?
    /// A second signal that needs no tmutil: an APFS Time Machine destination
    /// carries the Backup role.
    func isBackupDestination(_ volume: Volume) -> Bool
}

/// What a park may do about a backup in progress.
public enum BackupPolicy: Sendable {
    /// Refuse the park and name the volumes. Every automatic park, and the
    /// first try of one a person asked for.
    case refuseWhileBackingUp
    /// A person was told a backup is running and said park anyway.
    case stopBackupIfRunning
}

public enum BackupCheck: Equatable {
    case clear(note: String?)
    /// A backup is running onto these volumes, which the park would unmount.
    case backingUp([Volume])
}

/// The decision, a pure function of what was read.
public func backupCheck(toUnmount volumes: [Volume], status: BackupStatus?,
                        isDestination: (Volume) -> Bool) -> BackupCheck {
    guard let status else {
        let named = volumes.filter(isDestination)
        guard !named.isEmpty else { return .clear(note: nil) }
        return .clear(note: "Could not ask Time Machine whether it is backing up to "
                      + named.map(\.displayName).joined(separator: ", ")
                      + "; parked without knowing.")
    }
    guard status.running else { return .clear(note: nil) }
    let known = Set(status.destinationMountPoints.map(resolvedPath))
    let destinations = volumes.filter { volume in
        guard let point = volume.mountPoint else { return false }
        return known.contains(resolvedPath(point)) || isDestination(volume)
    }
    guard !destinations.isEmpty else { return .clear(note: nil) }
    // When Time Machine names the destination it is writing to, only that one
    // is in the way. When it does not, any destination might be.
    if let active = status.activeMountPoint.map(resolvedPath) {
        let writing = destinations.filter { $0.mountPoint.map(resolvedPath) == active }
        return writing.isEmpty ? .clear(note: nil) : .backingUp(writing)
    }
    return .backingUp(destinations)
}

public struct SystemBackups: BackupReading {
    public init() {}

    public func backupStatus() -> BackupStatus? {
        guard let status = runPlistTool("/usr/bin/tmutil", ["status", "-X"], timeout: 5) else {
            return nil
        }
        guard Self.isRunning(status) else { return BackupStatus(running: false) }
        // Only asked while a backup runs: a park on a Mac that is not backing
        // up costs one tmutil launch, not two.
        let destinations = runPlistTool("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 5)
        return Self.parse(status: status, destinations: destinations)
    }

    public func isBackupDestination(_ volume: Volume) -> Bool {
        apfsRoles(ofVolume: volume.device).contains("Backup")
    }

    static func isRunning(_ status: [String: Any]) -> Bool {
        (status["Running"] as? NSNumber)?.boolValue
            ?? ((status["Running"] as? String) == "1")
    }

    /// `tmutil status -X` and `tmutil destinationinfo -X`. The running-backup
    /// shape has not been captured on the tower, which has no Time Machine
    /// destination, so every key is optional and two spellings of the mount
    /// point are accepted. Without a destination mount point the check falls
    /// back to the Backup role, and failing that to refusing on every known
    /// destination.
    static func parse(status: [String: Any], destinations: [String: Any]?) -> BackupStatus {
        var result = BackupStatus(running: isRunning(status))
        let entries = destinations?["Destinations"] as? [[String: Any]] ?? []
        func mountPoint(_ entry: [String: Any]) -> String? {
            (entry["MountPoint"] as? String) ?? (entry["Mount Point"] as? String)
        }
        result.destinationMountPoints = Set(entries.compactMap(mountPoint))
        if let id = status["DestinationID"] as? String,
           let entry = entries.first(where: { $0["ID"] as? String == id }),
           let point = mountPoint(entry) {
            result.activeMountPoint = point
        } else if let point = status["DestinationMountPoint"] as? String,
                  result.destinationMountPoints.contains(point) {
            result.activeMountPoint = point
        }
        return result
    }
}
