// StaleDeviceTests.swift: a BSD name is checked right before it is used.
//
// The names come from the read at the start of a run, and the retry ladder
// can make them ~17 s old. A bay that renumbers in that window leaves its old
// name on a different volume, or on nothing.

import XCTest
@testable import DriveParkKit

final class StaleDeviceTests: XCTestCase {
    /// Backup was disk26s1 when the run read the disks and is disk28s1 by the
    /// time of the unmount.
    private var renumberedBackup: Tower.Bay {
        var bay = Tower.bays[2]
        bay.disk = "disk27"
        bay.container = "disk28"
        bay.volume = "disk28s1"
        return bay
    }

    func testAVolumeThatMovedIsUnmountedWhereItIsNow() {
        let moved = [Tower.bays[0], Tower.bays[1], renumberedBackup]
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.backup])),
            .success(Tower.snapshot(mounted: [Tower.backup], bays: moved)),
            .success(Tower.snapshot(bays: moved))])
        let ops = FakeOps()
        ops.movedAway = ["disk26s1"]
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") }, ["unmount disk28s1"])
        XCTAssertTrue(outcome.parked)
    }

    /// The old name now holds nothing this run knows, and a fresh read cannot
    /// find the volume. Nothing is unmounted on a guess.
    func testAVolumeThatCannotBeFoundAgainIsNotTouched() {
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.backup])),
            .success(Tower.snapshot(bays: [Tower.bays[0], Tower.bays[1]]))])
        let ops = FakeOps()
        ops.movedAway = ["disk26s1"]
        let outcome = engine(discovery, ops).park()

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") }, [])
        XCTAssertFalse(outcome.parked)
        XCTAssertTrue(outcome.results.first?.refusal?.contains("not touched") ?? false)
    }

    /// Checked on every rung, not once: the first attempt is refused, and by
    /// the second the volume has moved.
    func testEveryAttemptChecksTheNameAgain() {
        let moved = [Tower.bays[0], Tower.bays[1], renumberedBackup]
        let discovery = FakeDiscovery([
            .success(Tower.snapshot(mounted: [Tower.backup])),
            .success(Tower.snapshot(mounted: [Tower.backup], bays: moved)),
            .success(Tower.snapshot(bays: moved))])
        let ops = MovesAfterFirstRefusal()
        let outcome = Engine(discovery: discovery, ops: ops, backups: FakeBackups(),
                             isIgnored: { _ in false }, retryDelays: [0, 0]).park()

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("unmount") },
                       ["unmount disk26s1", "unmount disk28s1"])
        XCTAssertTrue(outcome.parked)
    }

    func testAWakeMountFollowsTheVolumeToo() {
        let moved = [Tower.bays[0], Tower.bays[1], renumberedBackup]
        let discovery = FakeDiscovery([
            .success(Tower.snapshot()),
            .success(Tower.snapshot(bays: moved)),
            .success(Tower.snapshot(mounted: [Tower.backup], bays: moved))])
        let ops = FakeOps()
        ops.movedAway = ["disk26s1"]
        let outcome = engine(discovery, ops).mount(volumeUUIDs: [Tower.backup])

        XCTAssertEqual(ops.events.filter { $0.hasPrefix("mount") }, ["mount disk28s1"])
        XCTAssertEqual(outcome.mountedCount, 1)
    }

    /// No UUID: nothing to look it up by, so a moved one is left alone.
    func testAVolumeWithoutAUUIDThatMovedIsLeftAlone() {
        let stick = Volume(device: "disk30s1", name: "CAMERA", mountPoint: "/Volumes/CAMERA", uuid: nil)
        let ops = FakeOps()
        ops.movedAway = ["disk30s1"]
        XCTAssertNil(Engine.currentDevice(of: stick, lastKnown: "disk30s1", ops: ops,
                                          relocate: { _ in "disk31s1" }))
    }

    /// The veto matches on UUID, so a volume without one is parked and not
    /// held, and the park says so.
    func testAParkedVolumeWithoutAUUIDIsNamedAsNotHeld() {
        func card(mounted: Bool) -> DiskSnapshot {
            var disk = PhysicalDisk(device: "disk30")
            disk.directVolumes = [Volume(device: "disk30", name: "CAMERA",
                                         mountPoint: mounted ? "/Volumes/CAMERA" : nil, uuid: nil)]
            return DiskSnapshot(disks: [disk])
        }
        let discovery = FakeDiscovery([.success(card(mounted: true)), .success(card(mounted: false))])
        let ops = FakeOps()
        let outcome = engine(discovery, ops).park()

        XCTAssertTrue(outcome.parked)
        XCTAssertEqual(ops.vetoedVolumeUUIDs, [])
        XCTAssertTrue(outcome.notes.contains { $0.contains("CAMERA has no volume UUID, so DrivePark cannot keep it unmounted") })
    }
}

/// Refuses the first unmount, and then the bay renumbers.
private final class MovesAfterFirstRefusal: DiskOperating {
    private let inner = FakeOps()
    private var refused = false
    var events: [String] { inner.events }

    func unmount(volumeBSDName: String, force: Bool) -> OpResult {
        _ = inner.unmount(volumeBSDName: volumeBSDName, force: force)
        guard refused else {
            refused = true
            inner.movedAway = ["disk26s1"]
            return OpResult(success: false, detail: "Resource busy", busy: true)
        }
        return OpResult(success: true)
    }
    func mount(volumeBSDName: String) -> OpResult { inner.mount(volumeBSDName: volumeBSDName) }
    func eject(diskBSDName: String) -> OpResult { inner.eject(diskBSDName: diskBSDName) }
    func isAttached(diskBSDName: String) -> Bool { true }
    func identifies(_ volume: Volume, atBSDName bsdName: String) -> Bool {
        inner.identifies(volume, atBSDName: bsdName)
    }
    func blockers(mountPoint: String) -> [String] { [] }
    func wake(mountPoint: String, timeout: TimeInterval) -> WakeResult {
        inner.wake(mountPoint: mountPoint, timeout: timeout)
    }
    var vetoedVolumeUUIDs: Set<String> {
        get { inner.vetoedVolumeUUIDs }
        set { inner.vetoedVolumeUUIDs = newValue }
    }
}
