// HolderAndTimeMachineTests: who holds a veto, and what Time Machine holds.
//
// Holders: one record per process, and a record is only alive while its pid
// still names the process that wrote it (the liveness decision itself is in
// VetoHolderTests). Time Machine: what a park says about a destination. This
// Mac has no Time Machine destination, so the plists here are built to
// tmutil's documented shape, not captured from a backup.

import XCTest
@testable import DriveParkKit

final class HolderTests: XCTestCase {
    private let record: [String: Any] = ["name": "DrivePark", "uuids": ["a", "b"], "started": 1_000.25]

    func testRecordParsesFromItsKey() {
        let holder = VetoBroker.parseHolder(key: "vetoHolder.1552", value: record)
        XCTAssertEqual(holder, VetoBroker.Holder(pid: 1552, name: "DrivePark", uuids: ["a", "b"],
                                                 started: 1_000.25))
        XCTAssertTrue(holder?.canAnswer ?? false)
    }

    func testMalformedRecordsAreNotHolders() {
        XCTAssertNil(VetoBroker.parseHolder(key: "vetoHolder.", value: record))
        XCTAssertNil(VetoBroker.parseHolder(key: "vetoHolder.abc", value: record))
        XCTAssertNil(VetoBroker.parseHolder(key: "vetoHolder.0", value: record))
        XCTAssertNil(VetoBroker.parseHolder(key: "vetoHolder.12", value: "not a dictionary"))
    }

    /// A parsed record is judged by the same check as everything else: same
    /// pid and same start time, or it is somebody else.
    func testAParsedRecordOnAReusedPidIsNotTheHolder() throws {
        let holder = try XCTUnwrap(VetoBroker.parseHolder(key: "vetoHolder.1552", value: record))
        let later = ProcessIdentity(start: 4_600, name: "DrivePark")
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: holder.pid, recordedStart: holder.started,
                                                recordedName: holder.name, lookup: { _ in later }))
        let same = ProcessIdentity(start: 1_000.25, name: "DrivePark")
        XCTAssertTrue(VetoBroker.holderIsAlive(pid: holder.pid, recordedStart: holder.started,
                                               recordedName: holder.name, lookup: { _ in same }))
    }
}

final class TimeMachineDestinationTests: XCTestCase {
    func testNoDestinationParsesToNothing() {
        // Captured on this Mac 2026-10-06: `tmutil destinationinfo -X` with
        // no destination is an empty dictionary.
        let status = SystemBackups.parse(
            status: ["ClientID": "com.apple.backupd", "Percent": -1.0, "Running": false],
            destinations: [:])
        XCTAssertEqual(status, BackupStatus(running: false))
    }

    func testParkingADestinationSaysSo() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let backups = FakeBackups()
        backups.status = BackupStatus(running: false, destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, FakeOps(), backups: backups).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.notes.contains { $0.contains("Backup: Time Machine backs up here") })
    }

    /// A person said stop the backup and park, and backupd still refused.
    /// lsof sees nothing, because backupd runs as root; the failure names it.
    func testABackupThatStillHoldsTheVolumeIsNamedAsTheBlocker() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot(mounted: [Tower.backup]))])
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"],
                                      activeMountPoint: "/Volumes/Backup")
        let ops = FakeOps()
        ops.unmountAnswers["disk26s1"] = OpResult(success: false, detail: "Resource busy (0xc010)", busy: true)
        let outcome = engine(discovery, ops, backups: backups).park(backup: .stopBackupIfRunning)

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(outcome.blockerSummary, "Backup: Time Machine (a backup to this volume is running)")
    }
}
