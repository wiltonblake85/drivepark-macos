// CardTextTests.swift: a notch card says which drive, never who held it or
// where anything lives.

import XCTest
@testable import DriveParkKit

final class CardTextTests: XCTestCase {
    func testAFailedParkCardNamesTheDriveButNotTheProgram() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.plex]))])
        let ops = FakeOps()
        ops.unmountAnswers["disk24s1"] = OpResult(success: false, detail: "Resource busy (0xc010)", busy: true)
        ops.holders["/Volumes/Plex"] = ["IINA (pid 97495)"]
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertTrue(outcome.problem?.contains("IINA (pid 97495)") ?? false, "the menu keeps the detail")
        XCTAssertEqual(outcome.cardProblem, "Still mounted: Plex.")
    }

    func testANotSafeCardLeavesMountPointsOut() {
        let snapshot = Tower.snapshot(mounted: [Tower.backup], unaccounted: [
            UnaccountedMount(device: "disk30s1", mountPoint: "/Volumes/Private Stuff", why: .unattributed)])
        let reason = snapshot.verdict.cardReason ?? ""
        XCTAssertTrue(reason.contains("Backup still mounted"))
        XCTAssertTrue(reason.contains("1 other mount(s)"))
        XCTAssertFalse(reason.contains("/Volumes"))
        XCTAssertFalse(reason.contains("disk30"))
    }

    func testABackupRefusalCardSaysTimeMachine() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup]))])
        let backups = FakeBackups()
        backups.status = BackupStatus(running: true, destinationMountPoints: ["/Volumes/Backup"])
        let outcome = engine(discovery, FakeOps(), backups: backups).park()
        XCTAssertEqual(outcome.cardProblem, "Time Machine is backing up to Backup.")
    }
}

final class ScreenLockTests: XCTestCase {
    /// The two shapes read on the tower: no key while unlocked, true while
    /// locked. Anything else is not a lock.
    func testOnlyTheSessionRecordCountsAsLocked() {
        XCTAssertTrue(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(ScreenLock.isLocked(session: ["kCGSSessionOnConsoleKey": true]))
        XCTAssertFalse(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(ScreenLock.isLocked(session: nil))
    }
}
