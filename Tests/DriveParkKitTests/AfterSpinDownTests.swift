// AfterSpinDownTests: the check after the courtesy spin-down asks the
// kernel's mount table, not the drives.
//
// 2026-10-14, three parks on the tower: every volume unmounted and verified,
// the spin-down sent, and then a second full read ran `diskutil info` on each
// drive as it was stopping: 5.6, 7.7, 10.3 and 12.1 s, one after another. The
// last two ran past the 10 s timeout, the read failed, and each park said
// "Park failed, do not undock" over drives that were unmounted. The read that
// failed also dropped the veto, so for a minute nothing held the drives down.
//
// Now: nothing new in the kernel's mount table since the verified read, and
// that read stands. Anything new, and the disks are read again to name it. If
// that read cannot finish, the veto keeps what the read before the spin-down
// verified.

import XCTest
@testable import DriveParkKit

final class AfterSpinDownTests: XCTestCase {

    // MARK: - The park

    func testDrivesTooSlowToAnswerAfterTheSpinDownDoNotFailAVerifiedPark() {
        // A third read would stall, as it did on the tower. Nothing has
        // mounted, so it is never taken.
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot()),
                                       .failure(StalledRead())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("eject") }.count, 3)
        XCTAssertEqual(discovery.calls, 2)
        XCTAssertEqual(discovery.mountTableCalls, 1)
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.safeToPowerOff)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.keptParked, [])
        XCTAssertEqual(ops.vetoedVolumeUUIDs, Tower.all)
    }

    func testFailedReadAfterSomethingMountedKeepsWhatTheFirstReadVerified() {
        // Something new in the table after the spin-down, and the read to
        // see what it is stalls. Not safe, and said so; the three drives the
        // read before the spin-down verified unmounted stay held.
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot()),
                                       .failure(StalledRead())])
        discovery.mountTables = [[KernelMount(source: "/dev/disk30s1", mountPoint: "/Volumes/STICK")]]
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(discovery.calls, 3)
        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertTrue(outcome.failure?.contains("Could not verify after the spin-down") ?? false,
                      outcome.failure ?? "")
        XCTAssertEqual(ops.vetoedVolumeUUIDs, Tower.all)
        XCTAssertEqual(Set(outcome.keptParked.compactMap(\.uuid)), Tower.all)
        let notes = outcome.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Mounted since the verified read: /Volumes/STICK"), notes)
        XCTAssertTrue(notes.contains("the read after it did not finish"), notes)
    }

    func testFailedReadBeforeTheSpinDownStillKeepsNothingNew() {
        // Audit C1 is unchanged: no finished read, no new hold, no spin-down.
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .failure(StalledRead())])
        let ops = FakeOps()
        ops.vetoedVolumeUUIDs = [Tower.plex]
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [Tower.plex])
        XCTAssertEqual(discovery.mountTableCalls, 0)
        XCTAssertFalse(ops.events.contains { $0.hasPrefix("eject") })
    }

    func testMountTableThatCannotBeReadMeansAFullRead() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        discovery.mountTables = [nil]
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(discovery.calls, 3)
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.safeToPowerOff)
        XCTAssertTrue(outcome.notes.contains { $0.contains("could not be read after the spin-down") },
                      outcome.notes.joined(separator: "\n"))
    }

    func testAReadThatKeptNoMountTableMeansAFullRead() {
        var verified = Tower.snapshot()
        verified.kernelMounts = nil
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(verified)])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(discovery.calls, 3)
        XCTAssertEqual(discovery.mountTableCalls, 0)
        XCTAssertTrue(outcome.parked)
    }

    func testAnIgnoredVolumeStillMountedIsNothingNew() {
        // Plex is ignored and mounted, in the table before and after. Its
        // disk keeps spinning, the other two get the eject, and nothing is
        // read again.
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot(mounted: [Tower.plex]))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops, ignored: { $0 == Tower.plex }).park()

        XCTAssertEqual(discovery.calls, 2)
        XCTAssertFalse(ops.events.contains("eject disk23"))
        XCTAssertTrue(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
    }

    // MARK: - What counts as new in the table

    func testOnlyNewDiskMountsOutsideTheSystemCount() {
        let before = [KernelMount(source: "/dev/disk3s1s1", mountPoint: "/"),
                      Tower.kernelMount(Tower.bays[0])]
        let now = before + [
            KernelMount(source: "map auto_home", mountPoint: "/System/Volumes/Data/home"),
            KernelMount(source: "devfs", mountPoint: "/dev"),
            KernelMount(source: "/dev/disk3s7", mountPoint: "/System/Volumes/Update/mnt1"),
            KernelMount(source: "//guest@nas/share", mountPoint: "/Volumes/share"),
            Tower.kernelMount(Tower.bays[2]),
        ]
        XCTAssertEqual(Engine.mountsAppeared(since: before, now: now).map(\.mountPoint),
                       ["/Volumes/Backup"])
    }

    func testTheSameVolumeAtANewMountPointCounts() {
        let before = [Tower.kernelMount(Tower.bays[1])]
        let now = [KernelMount(source: "/dev/disk24s1", mountPoint: "/Volumes/Plex 1")]
        XCTAssertEqual(Engine.mountsAppeared(since: before, now: now).count, 1)
    }

    func testAMountThatWentAwayIsNotNew() {
        XCTAssertEqual(Engine.mountsAppeared(since: [Tower.kernelMount(Tower.bays[1])], now: []), [])
    }

    // MARK: - Which disk events the park already answered

    func testADiskEventBeforeTheLastCheckIsAnswered() throws {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let before = Date()
        let outcome = engine(discovery, FakeOps()).park()
        let checked = try XCTUnwrap(outcome.checkedAt)

        XCTAssertTrue(outcome.answersDiskChange(deliveredAt: before))
        XCTAssertTrue(outcome.answersDiskChange(deliveredAt: checked))
        XCTAssertFalse(outcome.answersDiskChange(deliveredAt: checked.addingTimeInterval(0.001)))
    }

    func testAParkThatFailedAnswersNothing() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .failure(StalledRead())])
        let before = Date()
        let outcome = engine(discovery, FakeOps()).park()

        XCTAssertNotNil(outcome.failure)
        XCTAssertFalse(outcome.answersDiskChange(deliveredAt: before))
    }

    func testAParkThatTouchedNothingAnswersNothing() {
        let outcome = engine(FakeDiscovery([.success(Tower.snapshot())]), FakeOps()).park()

        XCTAssertNil(outcome.checkedAt)
        XCTAssertFalse(outcome.answersDiskChange(deliveredAt: .distantPast))
    }
}
