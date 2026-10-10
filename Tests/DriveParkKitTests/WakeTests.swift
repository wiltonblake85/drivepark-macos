// WakeTests: the park wakes every drive it is about to unmount, all at once,
// before asking macOS for the first unmount (SPEC section 10, 2026-10-10).

import XCTest
@testable import DriveParkKit

final class WakeTests: XCTestCase {

    private func wakes(_ ops: FakeOps) -> [String] {
        ops.events.filter { $0.hasPrefix("wake ") }
    }

    func testEveryDriveIsWokenOnceBeforeTheFirstUnmount() throws {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.parked)
        XCTAssertEqual(Set(wakes(ops)), ["wake /Volumes/Bottom Drawer", "wake /Volumes/Plex",
                                         "wake /Volumes/Backup"])
        XCTAssertEqual(wakes(ops).count, 3)
        let events = ops.events
        let lastWake = try XCTUnwrap(events.lastIndex { $0.hasPrefix("wake ") })
        let firstUnmount = try XCTUnwrap(events.firstIndex { $0.hasPrefix("unmount ") })
        XCTAssertLessThan(lastWake, firstUnmount, events.joined(separator: "\n"))
        // After the veto is armed, so nothing a wake might set off can
        // remount a volume with no veto standing.
        let firstVeto = try XCTUnwrap(events.firstIndex { $0.hasPrefix("veto [") })
        let firstWake = try XCTUnwrap(events.firstIndex { $0.hasPrefix("wake ") })
        XCTAssertLessThan(firstVeto, firstWake)
    }

    func testOnlyDrivesWithSomethingToUnmountAreWoken() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        _ = engine(discovery, ops).park()
        XCTAssertEqual(wakes(ops), ["wake /Volumes/Backup"])
    }

    func testAnIgnoredDriveIsNeverWoken() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.plex, Tower.backup])),
                                       .success(Tower.snapshot(mounted: [Tower.plex]))])
        let ops = FakeOps()
        _ = engine(discovery, ops, ignored: { $0 == Tower.plex }).park()
        XCTAssertEqual(wakes(ops), ["wake /Volumes/Backup"])
    }

    func testADriveParkWakesOnlyThatDrive() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot(mounted: [Tower.bottomDrawer, Tower.backup]))])
        let ops = FakeOps()
        _ = engine(discovery, ops).park(onlyDisks: ["disk23"])
        XCTAssertEqual(wakes(ops), ["wake /Volumes/Plex"])
    }

    func testForceWakesOnlyTheConfirmedVolume() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.plex, Tower.backup])),
                                       .success(Tower.snapshot(mounted: [Tower.plex]))])
        let ops = FakeOps()
        _ = engine(discovery, ops).forceUnmount(volumeUUIDs: [Tower.backup])
        XCTAssertEqual(wakes(ops), ["wake /Volumes/Backup"])
    }

    func testADriveThatDoesNotAnswerIsParkedAnyway() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        ops.wakeAnswers["/Volumes/Plex"] = .timedOut
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(ops.events.contains("unmount disk24s1"))
        XCTAssertTrue(outcome.notes.contains("Plex did not answer a read within 15 s; parking it anyway."),
                      outcome.notes.joined(separator: "\n"))
    }

    func testDrivesThatHadSpunDownAreNamedWithTheirTimes() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        ops.wakeAnswers["/Volumes/Plex"] = .woke(seconds: 10.4)
        ops.wakeAnswers["/Volumes/Backup"] = .woke(seconds: 12.3)
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.notes.contains("Woke the drives first, all at once: Plex 10.4 s, Backup 12.3 s."),
                      outcome.notes.joined(separator: "\n"))
    }

    func testAwakeDrivesAreNotMentioned() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()
        XCTAssertFalse(outcome.notes.contains { $0.hasPrefix("Woke") || $0.contains("did not answer") })
    }

    // MARK: - The budget

    func testTheBudgetLeavesSixSecondsBeforeSleep() {
        let now = Date()
        XCTAssertEqual(Engine.wakeBudget(deadline: nil, now: now), 15)
        XCTAssertEqual(Engine.wakeBudget(deadline: now.addingTimeInterval(19.5), now: now), 13.5, accuracy: 0.001)
        XCTAssertEqual(Engine.wakeBudget(deadline: now.addingTimeInterval(60), now: now), 15)
        XCTAssertLessThan(Engine.wakeBudget(deadline: now.addingTimeInterval(5), now: now), 1)
    }

    func testASleepParkPassesTheShorterBudgetToEveryWake() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        _ = engine(discovery, ops).park(deadline: Date().addingTimeInterval(16))
        XCTAssertEqual(ops.wakeBudgets.count, 3)
        for budget in ops.wakeBudgets {
            XCTAssertLessThanOrEqual(budget, 10.01)
            XCTAssertGreaterThan(budget, 9)
        }
    }

    func testNoTimeLeftMeansNoWakeAndTheParkStillRuns() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park(deadline: Date().addingTimeInterval(4))
        XCTAssertEqual(wakes(ops), [])
        XCTAssertTrue(outcome.notes.contains("Did not wake the drives first: out of time before sleep."))
        XCTAssertTrue(ops.events.contains("unmount disk26s1"))
    }

    func testTheWakeHasItsOwnLineInTheTiming() {
        XCTAssertTrue(ParkTiming().summary.contains("wake 0.00"))
    }

    // MARK: - The real read, against a scratch folder

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivepark-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheReadFindsAFileSomeLevelsDown() throws {
        let root = try scratch()
        let deep = root.appendingPathComponent("Movies/2026")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: deep.appendingPathComponent("clip.mkv"))
        XCTAssertTrue(uncachedProbeRead(under: root.path))
    }

    func testHiddenFilesAndLinksAreNeverRead() throws {
        let root = try scratch()
        try Data(count: 300_000).write(to: root.appendingPathComponent(".Spotlight-store"))
        let outside = try scratch().appendingPathComponent("elsewhere.bin")
        try Data(count: 300_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.bin"),
                                                   withDestinationURL: outside)
        XCTAssertFalse(uncachedProbeRead(under: root.path))
    }

    func testAnEmptyVolumeHasNothingToRead() throws {
        let root = try scratch()
        try Data(count: 100).write(to: root.appendingPathComponent("tiny.txt"))
        XCTAssertFalse(uncachedProbeRead(under: root.path))
        let ops = try XCTUnwrap(DiskOps())
        XCTAssertEqual(ops.wake(mountPoint: root.path, timeout: 5), .nothingToRead)
    }

    func testTheRealWakeAnswersWithHowLongItTook() throws {
        let root = try scratch()
        try Data(count: 300_000).write(to: root.appendingPathComponent("a.bin"))
        let ops = try XCTUnwrap(DiskOps())
        guard case .woke(let seconds) = ops.wake(mountPoint: root.path, timeout: 5) else {
            return XCTFail("expected a read")
        }
        XCTAssertLessThan(seconds, 5)
    }

    func testAWakeThatNeverAnswersGivesUpOnTime() {
        let box = WakeBox()
        let started = Date()
        XCTAssertNil(box.wait(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        box.finish(.woke(seconds: 1))
        XCTAssertEqual(box.wait(timeout: 0.2), .woke(seconds: 1))
    }
}
