// SpinDownTests — which disks get the courtesy spin-down after a park.
//
// The tower on 2026-10-02: Backup mounted, Bottom Drawer and Plex parked by
// earlier runs and asleep. The eject went to all three, woke the two sleepers
// one after the other, and the park spent 18.5 s in spin-down against 0.3 s
// of unmount. Only a disk this run took a volume off gets the eject now.

import XCTest
@testable import DriveParkKit

final class SpinDownTests: XCTestCase {
    private let notIgnored: (String?) -> Bool = { _ in false }

    private func disk(_ device: String, _ volumes: [Volume]) -> PhysicalDisk {
        var disk = PhysicalDisk(device: device)
        disk.containers = [Container(device: device + "-container",
                                     physicalStore: device + "s2",
                                     volumes: volumes)]
        return disk
    }

    private func volume(_ device: String, mountedAt mountPoint: String? = nil,
                        uuid: String = UUID().uuidString) -> Volume {
        Volume(device: device, name: device, mountPoint: mountPoint, uuid: uuid)
    }

    func testDiskParkedByAnEarlierRunIsLeftAsleep() {
        // The defect. Nothing mounted, so the old loop sent it an eject.
        let plex = disk("disk8", [volume("disk9s1")])
        XCTAssertEqual(Engine.spinDownDecision(for: plex, unmountedThisRun: ["disk10"],
                                               isIgnored: notIgnored),
                       .notThisRun)
    }

    func testDiskThisRunUnmountedGetsTheEject() {
        let backup = disk("disk10", [volume("disk11s1")])
        XCTAssertEqual(Engine.spinDownDecision(for: backup, unmountedThisRun: ["disk10"],
                                               isIgnored: notIgnored),
                       .send)
    }

    func testTowerParkWithTwoBaysAlreadyParkedSendsOneEject() {
        // The 2026-10-02 runs, as they will now go.
        let after = [disk("disk10", [volume("disk11s1")]),
                     disk("disk6", [volume("disk7s1")]),
                     disk("disk8", [volume("disk9s1")])]
        let sent = after.filter {
            Engine.spinDownDecision(for: $0, unmountedThisRun: ["disk10"],
                                    isIgnored: notIgnored) == .send
        }
        XCTAssertEqual(sent.map(\.device), ["disk10"])
    }

    func testIgnoredVolumeStillMountedKeepsTheDiskSpinning() {
        let keep = "IGNORED-UUID"
        let mixed = disk("disk6", [volume("disk7s1"),
                                   volume("disk7s2", mountedAt: "/Volumes/Scratch", uuid: keep)])
        XCTAssertEqual(Engine.spinDownDecision(for: mixed, unmountedThisRun: ["disk6"],
                                               isIgnored: { $0 == keep }),
                       .leftSpinningForIgnored)
    }

    func testVolumeThatFailedToUnmountMeansNoEject() {
        let partial = disk("disk6", [volume("disk7s1"),
                                     volume("disk7s2", mountedAt: "/Volumes/Busy")])
        XCTAssertEqual(Engine.spinDownDecision(for: partial, unmountedThisRun: ["disk6"],
                                               isIgnored: notIgnored),
                       .stillMounted)
    }
}
