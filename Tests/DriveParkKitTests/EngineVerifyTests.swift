// EngineVerifyTests: a park is a claim about a fresh read, and nothing else.
//
// Audit 2026-10-05. C1: discovery answered [] when diskutil failed, and the
// verify step read [] as "nothing still mounted", so a stalled enclosure
// turned three failed unmounts into a verified park. H5: the veto went up
// after the spin-down. H4: force acted on stale, wider state. Each test below
// is one of those, run against fakes that fail on cue.

import XCTest
@testable import DriveParkKit

final class EngineVerifyTests: XCTestCase {

    // MARK: - C1: a read that fails is not a read that found nothing

    func testDiscoveryThatFailsOnItsSecondCallIsNotParked() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .failure(StalledRead())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertNotNil(outcome.failure)
        XCTAssertTrue(outcome.failure?.contains("Could not verify") ?? false, outcome.failure ?? "")
        XCTAssertEqual(discovery.calls, 2)
        // No veto left standing over volumes nobody verified, and no
        // spin-down after an unverified park.
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
        XCTAssertFalse(ops.events.contains { $0.hasPrefix("eject") })
        // It did try: this is the case where the unmounts ran and the read
        // after them failed.
        XCTAssertTrue(outcome.didWork)
    }

    func testDiscoveryThatFailsBeforeTheParkTouchesNothing() {
        let discovery = FakeDiscovery([.failure(StalledRead())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertTrue(outcome.failure?.contains("nothing was touched") ?? false)
        XCTAssertEqual(ops.events, [])
    }

    func testVolumeSeenBeforeAndMissingAfterIsNotParked() {
        let withoutPlex = Tower.bays.filter { $0.uuid != Tower.plex }
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all)),
                                       .success(Tower.snapshot(bays: withoutPlex))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertEqual(outcome.missing.compactMap(\.uuid), [Tower.plex])
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
    }

    func testDriveParkThatRenumberedAndStayedMountedIsNotParked() {
        // The `--only` case from the audit. Plex was disk23 before the park and
        // disk27 after it, still mounted. Filtering the second read by the old
        // name dropped it, and an empty list read as parked.
        var renumbered = Tower.bays[1]
        renumbered.disk = "disk27"
        renumbered.container = "disk28"
        renumbered.volume = "disk28s1"
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: Tower.all)),
            .success(Tower.snapshot(mounted: [Tower.plex], bays: [Tower.bays[0], renumbered, Tower.bays[2]]))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park(onlyDisks: ["disk23"])

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(outcome.stillMounted.map(\.device), ["disk28s1"])
    }

    func testDriveParkThatRenumberedAndUnmountedIsFoundByUUID() {
        var renumbered = Tower.bays[1]
        renumbered.disk = "disk27"
        renumbered.container = "disk28"
        renumbered.volume = "disk28s1"
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.plex])),
            .success(Tower.snapshot(bays: [Tower.bays[0], renumbered, Tower.bays[2]]))])
        let outcome = engine(discovery, FakeOps()).park(onlyDisks: ["disk23"])

        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.safeToPowerOff)
    }

    func testOnlyNamingNoDiskTouchesNothing() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park(onlyDisks: ["disk99"])

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(ops.events, [])
    }

    // MARK: - H1: the ignore list does not make anything safe

    func testIgnoredVolumeStillMountedIsParkedButNotSafe() {
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.plex, Tower.backup])),
            .success(Tower.snapshot(mounted: [Tower.plex]))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops, ignored: { $0 == Tower.plex }).park()

        // Everything DrivePark manages is down, which is all a park can do.
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.didWork)
        // And it is not safe to pull the cable, which is what the checkmark
        // used to say.
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertTrue(outcome.safetyReason?.contains("Plex (on the ignore list)") ?? false,
                      outcome.safetyReason ?? "")
        XCTAssertFalse(ops.events.contains("unmount disk24s1"))
        // The bay under the ignored volume keeps spinning.
        XCTAssertFalse(ops.events.contains("eject disk23"))
    }

    func testNothingMountedAtAllIsSafe() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let outcome = engine(discovery, FakeOps()).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.safeToPowerOff)
        XCTAssertNil(outcome.safetyReason)
    }

    func testMountTheReadCannotAccountForIsNotSafe() {
        let stick = UnaccountedMount(device: "disk20", mountPoint: "/Volumes/STICK",
                                     why: .onDiscoveredDisk)
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot(unaccounted: [stick]))])
        let outcome = engine(discovery, FakeOps()).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertTrue(outcome.safetyReason?.contains("/Volumes/STICK") ?? false)
    }

    // MARK: - H5: the veto goes up first, and the spin-down is checked

    func testVetoIsArmedBeforeTheFirstUnmount() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.parked)
        let events = ops.events
        let firstVeto = events.firstIndex { $0.hasPrefix("veto") }
        let firstUnmount = events.firstIndex { $0.hasPrefix("unmount") }
        XCTAssertNotNil(firstVeto)
        XCTAssertNotNil(firstUnmount)
        XCTAssertLessThan(firstVeto!, firstUnmount!, events.joined(separator: "\n"))
        XCTAssertTrue(ops.vetoedVolumeUUIDs.contains(Tower.backup))
    }

    func testVetoIsDroppedWhenTheParkFails() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot(mounted: [Tower.backup]))])
        let ops = FakeOps()
        ops.unmountAnswers["disk26s1"] = OpResult(success: false, detail: "Resource busy (0xc010)", busy: true)
        ops.holders["/Volumes/Backup"] = ["sleep (pid 4242)"]
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
        XCTAssertTrue(ops.events.contains { $0.hasPrefix("veto [") && $0.contains(Tower.backup) })
        XCTAssertEqual(outcome.blockerSummary, "Backup: sleep (pid 4242)")
        XCTAssertEqual(outcome.results.first?.refusal, "Resource busy (0xc010)")
    }

    func testVolumeBackAfterTheSpinDownIsCaught() {
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.backup])),
            .success(Tower.snapshot()),
            .success(Tower.snapshot(mounted: [Tower.backup]))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(ops.events.contains("eject disk25"))
        XCTAssertEqual(discovery.calls, 3)
        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
        XCTAssertTrue(outcome.notes.contains { $0.contains("mounted again after the spin-down") })
    }

    func testVerifiedParkReadsTwiceAndKeepsTheVeto() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.safeToPowerOff)
        XCTAssertEqual(discovery.calls, 3)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, Tower.all)
    }

    func testFailedReadAfterTheSpinDownIsNotParked() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot()),
                                       .failure(StalledRead())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
    }

    // MARK: - H4: force touches what was confirmed, found fresh

    private func twoVolumeBay(_ device: String = "disk26s1", scratch: String = "disk26s2",
                              backupMounted: Bool = true) -> DiskSnapshot {
        var disk = PhysicalDisk(device: "disk25")
        disk.containers = [Container(device: "disk26", physicalStore: "disk25s2", volumes: [
            Volume(device: device, name: "Backup",
                   mountPoint: backupMounted ? "/Volumes/Backup" : nil, uuid: Tower.backup),
            Volume(device: scratch, name: "Scratch", mountPoint: "/Volumes/Scratch", uuid: "scratch-uuid"),
        ])]
        return DiskSnapshot(disks: [disk])
    }

    func testForceTouchesOnlyTheConfirmedVolume() {
        let discovery = FakeDiscovery([.success(twoVolumeBay()),
                                       .success(twoVolumeBay(backupMounted: false))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).forceUnmount(volumeUUIDs: [Tower.backup.uppercased()])

        let unmounts = ops.events.filter { $0.hasPrefix("unmount") }
        XCTAssertEqual(unmounts, ["unmount disk26s1 force"])
        XCTAssertTrue(outcome.parked)
        // Scratch shares the disk and is still mounted, so nothing is safe and
        // the disk is not spun down under it.
        XCTAssertFalse(outcome.safeToPowerOff)
        XCTAssertFalse(ops.events.contains("eject disk25"))
    }

    func testForceFollowsTheVolumeToItsCurrentDevice() {
        let discovery = FakeDiscovery([.success(twoVolumeBay("disk30s1", scratch: "disk30s2")),
                                       .success(twoVolumeBay("disk30s1", scratch: "disk30s2",
                                                             backupMounted: false))])
        let ops = FakeOps()
        _ = engine(discovery, ops).forceUnmount(volumeUUIDs: [Tower.backup])
        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") }, ["unmount disk30s1 force"])
    }

    func testForceThatCannotMapItsVolumeTouchesNothing() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).forceUnmount(volumeUUIDs: ["not-attached-anymore"])
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(ops.events, [])
    }

    func testForceNeverWidensWhenTheReadComesBackEmpty() {
        // The old path: a timed-out refresh left the disk list empty, the
        // mapping found no disk, and the force ran with no scope at all.
        let discovery = FakeDiscovery([.success(DiskSnapshot(disks: []))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).forceUnmount(volumeUUIDs: [Tower.backup])
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(ops.events, [])
    }

    func testForceCheckReadsTheHoldersAgain() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup]))])
        let ops = FakeOps()
        ops.holders["/Volumes/Backup"] = ["IINA (pid 97495)"]
        guard case .ready(let volumes, let blockers) =
                engine(discovery, ops).checkForce(volumeUUIDs: [Tower.backup]) else {
            return XCTFail("expected a ready check")
        }
        XCTAssertEqual(volumes.compactMap(\.uuid), [Tower.backup])
        XCTAssertEqual(blockers, ["IINA (pid 97495)"])
    }

    func testForceCheckOnAVolumeNoLongerMountedOffersNothing() {
        let discovery = FakeDiscovery([.success(Tower.snapshot())])
        guard case .refused(let reason) =
                engine(discovery, FakeOps()).checkForce(volumeUUIDs: [Tower.backup]) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("no longer mounted"))
    }

    // MARK: - The veto's lifecycle

    func testMountDropsTheVeto() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot()),
                                       .success(Tower.snapshot()),
                                       .success(Tower.snapshot()),
                                       .success(Tower.snapshot(mounted: Tower.all))])
        let ops = FakeOps()
        let engine = engine(discovery, ops)
        XCTAssertTrue(engine.park().parked)
        XCTAssertTrue(engine.isVetoActive)

        let mounted = engine.mount()
        XCTAssertFalse(engine.isVetoActive)
        XCTAssertNil(mounted.failure)
        XCTAssertEqual(mounted.mountedCount, 3)
    }

    func testIgnoringAVolumeLiftsItsVeto() {
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: [Tower.backup])),
                                       .success(Tower.snapshot())])
        let ops = FakeOps()
        var ignored: Set<String> = []
        let engine = Engine(discovery: discovery, ops: ops, backups: FakeBackups(),
                            isIgnored: { $0.map(ignored.contains) ?? false }, retryDelays: [0])
        XCTAssertTrue(engine.park().parked)
        XCTAssertTrue(ops.vetoedVolumeUUIDs.contains(Tower.backup))

        ignored.insert(Tower.backup)
        engine.liftVetoForIgnored()
        XCTAssertFalse(ops.vetoedVolumeUUIDs.contains(Tower.backup))
        XCTAssertTrue(ops.vetoedVolumeUUIDs.contains(Tower.plex))
    }

    func testParkWithNothingMountedLeavesTheVetoAlone() {
        let discovery = FakeDiscovery([.success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertFalse(outcome.didWork)
        XCTAssertEqual(ops.events, [])
    }

    // MARK: - Per-drive buttons find the drive as it is now

    private func renumberedPlex(mounted: Bool) -> DiskSnapshot {
        var plex = Tower.bays[1]
        plex.disk = "disk27"
        plex.container = "disk28"
        plex.volume = "disk28s1"
        return Tower.snapshot(mounted: mounted ? [Tower.plex] : [],
                              bays: [Tower.bays[0], plex, Tower.bays[2]])
    }

    func testDriveParkFindsARenumberedDriveByItsVolumes() {
        // The menu saw Plex on disk23. By the click it is disk27, and disk23
        // is gone. A park by the old name would refuse, or worse, find a
        // different bay under it.
        let discovery = FakeDiscovery([.success(renumberedPlex(mounted: true)),
                                       .success(renumberedPlex(mounted: false))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park(drivesHolding: [Tower.plex])

        XCTAssertTrue(outcome.parked)
        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") }, ["unmount disk28s1"])
        XCTAssertTrue(ops.events.contains("eject disk27"))
    }

    func testDriveParkOfADriveNoLongerAttachedTouchesNothing() {
        let withoutPlex = Tower.bays.filter { $0.uuid != Tower.plex }
        let discovery = FakeDiscovery([.success(Tower.snapshot(mounted: Tower.all, bays: withoutPlex))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park(drivesHolding: [Tower.plex])
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(ops.events, [])
    }

    func testDriveMountFindsARenumberedDrive() {
        let discovery = FakeDiscovery([.success(renumberedPlex(mounted: false)),
                                       .success(renumberedPlex(mounted: true))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).mount(drivesHolding: [Tower.plex])
        XCTAssertEqual(ops.events.filter { $0.hasPrefix("mount") }, ["mount disk28s1"])
        XCTAssertEqual(outcome.mountedCount, 1)
    }

    func testVolumeWithNoUUIDIsSaidOutLoud() {
        var stick = PhysicalDisk(device: "disk20")
        stick.directVolumes = [Volume(device: "disk20", name: "STICK", mountPoint: "/Volumes/STICK", uuid: nil)]
        var parked = stick
        parked.directVolumes = [Volume(device: "disk20", name: "STICK", mountPoint: nil, uuid: nil)]
        let discovery = FakeDiscovery([.success(DiskSnapshot(disks: [stick])),
                                       .success(DiskSnapshot(disks: [parked]))])
        let outcome = engine(discovery, FakeOps()).park()
        XCTAssertTrue(outcome.parked)
        XCTAssertTrue(outcome.notes.contains { $0.contains("STICK has no volume UUID") })
    }

    // MARK: - Mount on wake undoes only what was named

    func testWakeMountTouchesOnlyTheVolumesItWasGiven() {
        // Backup was taken down by a screen-lock park. Bottom Drawer and Plex
        // were parked by hand and must stay parked, with their veto up.
        let discovery = FakeDiscovery([.success(Tower.snapshot()),
                                       .success(Tower.snapshot(mounted: [Tower.backup]))])
        let ops = FakeOps()
        ops.vetoedVolumeUUIDs = Tower.all
        let outcome = engine(discovery, ops).mount(volumeUUIDs: [Tower.backup.uppercased()])

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("mount") }, ["mount disk26s1"])
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [Tower.bottomDrawer, Tower.plex])
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.mountedCount, 1)
        XCTAssertEqual(outcome.total, 1)
    }

    func testWakeMountLeavesTheOtherVolumeOnTheSameDiskParked() {
        // Same disk, two volumes: the automatic park took down Backup, and
        // Scratch was parked by hand. Mounting "the disk Backup is on" would
        // bring Scratch back too.
        func bay(_ mounted: Bool) -> DiskSnapshot {
            var disk = PhysicalDisk(device: "disk25")
            disk.containers = [Container(device: "disk26", physicalStore: "disk25s2", volumes: [
                Volume(device: "disk26s1", name: "Backup",
                       mountPoint: mounted ? "/Volumes/Backup" : nil, uuid: Tower.backup),
                Volume(device: "disk26s2", name: "Scratch", mountPoint: nil, uuid: "scratch-uuid"),
            ])]
            return DiskSnapshot(disks: [disk])
        }
        let discovery = FakeDiscovery([.success(bay(false)), .success(bay(true))])
        let ops = FakeOps()
        ops.vetoedVolumeUUIDs = [Tower.backup, "scratch-uuid"]
        let outcome = engine(discovery, ops).mount(volumeUUIDs: [Tower.backup])

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("mount") }, ["mount disk26s1"])
        XCTAssertEqual(ops.vetoedVolumeUUIDs, ["scratch-uuid"])
        XCTAssertEqual(outcome.total, 1)
        XCTAssertEqual(outcome.mountedCount, 1)
    }

    func testWakeMountOfAVolumeNoLongerAttachedCountsItAsNotMounted() {
        let withoutBackup = Tower.bays.filter { $0.uuid != Tower.backup }
        let discovery = FakeDiscovery([.success(Tower.snapshot(bays: withoutBackup))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).mount(volumeUUIDs: [Tower.backup])

        XCTAssertFalse(ops.events.contains { $0.hasPrefix("mount") })
        XCTAssertEqual(outcome.total, 1)
        XCTAssertEqual(outcome.mountedCount, 0)
    }

    func testWakeMountLeavesAnIgnoredVolumeAlone() {
        let discovery = FakeDiscovery([.success(Tower.snapshot())])
        let ops = FakeOps()
        let outcome = engine(discovery, ops, ignored: { $0 == Tower.backup })
            .mount(volumeUUIDs: [Tower.backup])
        XCTAssertFalse(ops.events.contains { $0.hasPrefix("mount") })
        XCTAssertEqual(outcome.total, 0)
    }

    func testTowerMountStillMountsEverythingAndDropsTheWholeVeto() {
        let discovery = FakeDiscovery([.success(Tower.snapshot()),
                                       .success(Tower.snapshot(mounted: Tower.all))])
        let ops = FakeOps()
        ops.vetoedVolumeUUIDs = Tower.all
        let outcome = engine(discovery, ops).mount()
        XCTAssertEqual(ops.events.filter { $0.hasPrefix("mount") }.count, 3)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
        XCTAssertEqual(outcome.mountedCount, 3)
    }

    func testFailedMountReadIsReportedNotCounted() {
        let discovery = FakeDiscovery([.success(Tower.snapshot()), .failure(StalledRead())])
        let outcome = engine(discovery, FakeOps()).mount()
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(outcome.mountedCount, 0)
    }
}
