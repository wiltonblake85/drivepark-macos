// TimeMachineTests.swift: a park never stops a backup nobody was asked about.

import XCTest
@testable import DriveParkKit

final class TimeMachineTests: XCTestCase {
    private let backupVolume = Volume(device: "disk26s1", name: "Backup",
                                      mountPoint: "/Volumes/Backup", uuid: Tower.backup)
    private let plexVolume = Volume(device: "disk24s1", name: "Plex",
                                    mountPoint: "/Volumes/Plex", uuid: Tower.plex)
    private let noRole: (Volume) -> Bool = { _ in false }

    // MARK: - The decision

    func testNoBackupRunningIsClear() {
        let status = BackupStatus(running: false, destinationMountPoints: ["/Volumes/Backup"])
        XCTAssertEqual(backupCheck(toUnmount: [backupVolume, plexVolume], status: status,
                                   isDestination: noRole), .clear(note: nil))
    }

    func testABackupOntoAVolumeInTheParkIsNamed() {
        let status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        XCTAssertEqual(backupCheck(toUnmount: [backupVolume, plexVolume], status: status,
                                   isDestination: noRole), .backingUp([backupVolume]))
    }

    func testABackupOntoAVolumeOutsideTheParkIsClear() {
        let status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"],
                                  activeMountPoint: "/Volumes/Backup")
        XCTAssertEqual(backupCheck(toUnmount: [plexVolume], status: status, isDestination: noRole),
                       .clear(note: nil))
    }

    /// Two destinations configured, one being written: only that one is in
    /// the way.
    func testOnlyTheDestinationBeingWrittenIsInTheWay() {
        let status = BackupStatus(running: true,
                                  destinationMountPoints: ["/Volumes/Backup", "/Volumes/Plex"],
                                  activeMountPoint: "/Volumes/Plex")
        XCTAssertEqual(backupCheck(toUnmount: [backupVolume, plexVolume], status: status,
                                   isDestination: noRole), .backingUp([plexVolume]))
    }

    /// No mount point from tmutil, but the volume carries the Backup role.
    func testTheBackupRoleIsEnoughWhileABackupRuns() {
        let status = BackupStatus(running: true)
        XCTAssertEqual(backupCheck(toUnmount: [backupVolume, plexVolume], status: status,
                                   isDestination: { $0.device == "disk26s1" }),
                       .backingUp([backupVolume]))
    }

    /// tmutil did not answer. Not a reason to refuse every park, but not a
    /// thing to pass over in silence on a volume that is a destination.
    func testAnUnansweredTimeMachineIsSaidOutLoud() {
        guard case .clear(let note?) = backupCheck(toUnmount: [backupVolume], status: nil,
                                                   isDestination: { $0.device == "disk26s1" })
        else { return XCTFail("expected a clear with a note") }
        XCTAssertTrue(note.contains("Backup"))
        XCTAssertEqual(backupCheck(toUnmount: [plexVolume], status: nil, isDestination: noRole),
                       .clear(note: nil))
    }

    // MARK: - The engine

    /// The audit's case: an automatic park used to stop the backup silently.
    func testAnAutomaticParkDuringABackupTouchesNothing() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all))])
        let ops = FakeOps()
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, ops, backups: backups).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.didWork)
        XCTAssertEqual(outcome.backupInProgress.map(\.uuid), [Tower.backup])
        XCTAssertTrue(outcome.failure?.contains("Time Machine is backing up to Backup") ?? false)
        XCTAssertEqual(ops.events, [], "no unmount, and no veto armed")
    }

    /// A person was asked and said yes.
    func testAParkAPersonConfirmedStopsTheBackupAndSaysSo() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, ops, backups: backups).park(backup: .stopBackupIfRunning)

        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.backupInProgress.isEmpty)
        XCTAssertTrue(ops.events.contains("unmount disk26s1"))
        XCTAssertTrue(outcome.notes.contains { $0.contains("Time Machine was backing up to Backup") })
    }

    func testADriveParkAwayFromTheBackupGoesAhead() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot(mounted: [Tower.backup, Tower.bottomDrawer]))])
        let ops = FakeOps()
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, ops, backups: backups).park(onlyDisks: ["disk23"])

        XCTAssertTrue(outcome.parked)
        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") }, ["unmount disk24s1"])
    }

    func testANoOpParkDoesNotAskTimeMachine() {
        let discovery = FakeDiscovery([.success(Tower.snapshot())])
        let backups = FakeBackups()
        _ = engine(discovery, FakeOps(), backups: backups).park()
        XCTAssertEqual(backups.calls, 0)
    }

    /// lsof cannot see backupd, so the force prompt has to name it.
    func testTheForcePromptNamesABackupInProgress() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup]))])
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        guard case .ready(_, let blockers) = engine(discovery, FakeOps(), backups: backups)
            .checkForce(volumeUUIDs: [Tower.backup])
        else { return XCTFail("expected a force offer") }
        XCTAssertEqual(blockers, ["Time Machine, backing up to Backup"])
    }

    // MARK: - Reading tmutil

    func testTheDestinationBeingWrittenIsFoundByItsID() {
        let status: [String: Any] = ["Running": true, "DestinationID": "B2", "BackupPhase": "Copying"]
        let destinations: [String: Any] = ["Destinations": [
            ["ID": "A1", "Kind": "Local", "Name": "Plex", "MountPoint": "/Volumes/Plex"],
            ["ID": "B2", "Kind": "Local", "Name": "Backup", "MountPoint": "/Volumes/Backup"],
            ["ID": "C3", "Kind": "Network", "Name": "NAS", "URL": "smb://nas/tm"],
        ]]
        let parsed = SystemBackups.parse(status: status, destinations: destinations)
        XCTAssertTrue(parsed.running)
        XCTAssertEqual(parsed.destinationMountPoints, ["/Volumes/Plex", "/Volumes/Backup"])
        XCTAssertEqual(parsed.activeMountPoint, "/Volumes/Backup")
    }

    /// Captured from this Mac, 2026-10-07, with no backup running.
    func testAnIdleStatusIsNotRunning() {
        let idle: [String: Any] = ["ClientID": "com.apple.backupd", "Percent": -1, "Running": false]
        XCTAssertFalse(SystemBackups.isRunning(idle))
        XCTAssertTrue(SystemBackups.isRunning(["Running": 1]))
    }
}
