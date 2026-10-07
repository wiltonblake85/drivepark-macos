// HolderAndTimeMachineTests: who holds a veto, and what Time Machine holds.
//
// Holders: one record per process, and a record is only alive while its pid
// still names the process that wrote it. Time Machine: parsed from `tmutil
// -X` plists. This Mac has no Time Machine destination, so the plists here
// are built to tmutil's documented shape, not captured from a backup.

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

    func testAPidReusedByAnotherProcessIsNotTheHolder() {
        let holder = VetoBroker.Holder(pid: 1552, name: "DrivePark", uuids: ["a"], started: 1_000.25)
        // The same pid, alive, but started an hour later: a different process.
        XCTAssertFalse(VetoBroker.isAlive(holder, exists: { _ in true }, startTime: { _ in 4_600.0 }))
        XCTAssertTrue(VetoBroker.isAlive(holder, exists: { _ in true }, startTime: { _ in 1_000.4 }))
        XCTAssertFalse(VetoBroker.isAlive(holder, exists: { _ in false }, startTime: { _ in 1_000.25 }))
    }

    func testARecordWithNoStartTimeFallsBackToTheProcessExisting() {
        // What an older build wrote, carried across.
        let legacy = VetoBroker.Holder(pid: 1552, name: "DrivePark", uuids: ["a"], started: nil)
        XCTAssertTrue(VetoBroker.isAlive(legacy, exists: { _ in true }, startTime: { _ in 9_999 }))
    }

    func testThisProcessReadsItsOwnStartTime() {
        let started = VetoBroker.processStartTime(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(started)
        XCTAssertLessThan(abs((started ?? 0) - Date().timeIntervalSince1970), 3600)
    }
}

final class TimeMachineTests: XCTestCase {
    func testNoDestinationParsesToNothing() {
        // Captured on this Mac 2026-10-06: `tmutil destinationinfo -X` with
        // no destination is an empty dictionary.
        let state = parseTimeMachine(destinationInfo: [:],
                                     status: ["ClientID": "com.apple.backupd", "Percent": -1.0, "Running": false])
        XCTAssertEqual(state, TimeMachineState())
    }

    func testRunningBackupToANamedDestination() {
        let state = parseTimeMachine(
            destinationInfo: ["Destinations": [["Kind": "Local", "Name": "Backup",
                                                "MountPoint": "/Volumes/Backup", "ID": "X"]]],
            status: ["Running": 1, "DestinationMountPoint": "/Volumes/Backup"])
        XCTAssertTrue(state.isBackingUp(to: "/Volumes/Backup"))
        XCTAssertFalse(state.isBackingUp(to: "/Volumes/Plex"))
    }

    func testRunningBackupWithNoDestinationNamedCountsEveryMountedDestination() {
        let state = parseTimeMachine(
            destinationInfo: ["Destinations": [["MountPoint": "/Volumes/Backup"]]],
            status: ["Running": true])
        XCTAssertTrue(state.isBackingUp(to: "/Volumes/Backup"))
        XCTAssertFalse(state.isBackingUp(to: "/Volumes/Plex"))
    }

    func testParkingADestinationSaysSo() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        discovery.timeMachineState = TimeMachineState(destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, FakeOps()).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.notes.contains { $0.contains("Backup: Time Machine backs up here") })
    }

    func testABackupInProgressIsNamedAsTheBlocker() {
        // lsof sees nothing, because backupd runs as root. Before this the
        // failure had no blocker at all.
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot(mounted: [Tower.backup]))])
        discovery.timeMachineState = TimeMachineState(destinationMountPoints: ["/Volumes/Backup"],
                                                      backupRunning: true,
                                                      backingUpTo: "/Volumes/Backup")
        let ops = FakeOps()
        ops.unmountAnswers["disk26s1"] = OpResult(success: false, detail: "Resource busy (0xc010)", busy: true)
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(outcome.blockerSummary, "Backup: Time Machine (a backup to this volume is running)")
    }

    func testForcePromptNamesABackupInProgress() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup]))])
        discovery.timeMachineState = TimeMachineState(destinationMountPoints: ["/Volumes/Backup"],
                                                      backupRunning: true)
        guard case .ready(_, let blockers) =
                engine(discovery, FakeOps()).checkForce(volumeUUIDs: [Tower.backup]) else {
            return XCTFail("expected a ready check")
        }
        XCTAssertEqual(blockers, ["Time Machine (a backup to Backup is running)"])
    }
}
