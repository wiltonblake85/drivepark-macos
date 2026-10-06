// SafetyTests: what "safe to power off" is made of.
//
// H1: one answer, counting ignored volumes. H2: the kernel's mount table as a
// cross-check on discovery, so a volume diskutil could not place still keeps
// the answer at no. The mounts in the last test are the ones on this Mac on
// 2026-10-06 with the tower parked: the startup disk's seven, Xcode's
// simulator images, devfs and an autofs map. None of them may count.

import XCTest
@testable import DriveParkKit

final class SafetyTests: XCTestCase {

    private func volume(_ device: String, _ name: String, at mountPoint: String? = nil,
                        uuid: String? = nil) -> Volume {
        Volume(device: device, name: name, mountPoint: mountPoint, uuid: uuid)
    }

    // MARK: - The verdict

    func testIgnoredVolumeStillMountedIsNotSafe() {
        let verdict = Tower.snapshot(mounted: [Tower.plex]).verdict
        XCTAssertFalse(verdict.safeToPowerOff)
        XCTAssertEqual(verdict.reason(isIgnored: { $0 == Tower.plex }),
                       "Plex (on the ignore list) still mounted")
    }

    func testNothingMountedIsSafe() {
        let verdict = Tower.snapshot().verdict
        XCTAssertTrue(verdict.safeToPowerOff)
        XCTAssertNil(verdict.reason(isIgnored: { _ in false }))
    }

    func testUnaccountedMountAloneIsNotSafe() {
        let raid = UnaccountedMount(device: "disk30", mountPoint: "/Volumes/RAID", why: .unattributed)
        let verdict = Tower.snapshot(unaccounted: [raid]).verdict
        XCTAssertFalse(verdict.safeToPowerOff)
        XCTAssertTrue(verdict.reason(isIgnored: { _ in false })?.contains("/Volumes/RAID") ?? false)
    }

    // MARK: - Reading the kernel's mount table

    func testDeviceIsReadFromTheMountSource() {
        XCTAssertEqual(KernelMount(source: "/dev/disk22s1", mountPoint: "/Volumes/X").bsdDevice, "disk22s1")
        XCTAssertEqual(KernelMount(source: "/dev/disk3s1s1", mountPoint: "/").bsdDevice, "disk3s1s1")
        // FSKit exFAT on a whole disk, captured 2026-10-06.
        XCTAssertEqual(KernelMount(source: "/dev/disk27", mountPoint: "/Volumes/DPSTICK").bsdDevice, "disk27")
        // A mounted snapshot pins its volume like any other mount.
        XCTAssertEqual(KernelMount(source: "com.apple.TimeMachine.2026-10-06-090000.local@/dev/disk22s1",
                                   mountPoint: "/Volumes/.timemachine/x").bsdDevice, "disk22s1")
        XCTAssertNil(KernelMount(source: "devfs", mountPoint: "/dev").bsdDevice)
        XCTAssertNil(KernelMount(source: "map auto_home", mountPoint: "/System/Volumes/Data/home").bsdDevice)
        XCTAssertNil(KernelMount(source: "//guest@nas/share", mountPoint: "/Volumes/share").bsdDevice)
    }

    func testContainersResolveToTheirPhysicalDisks() {
        let stores: [String: Set<String>] = ["disk3": ["disk0"], "disk5": ["disk4"], "disk22": ["disk21"]]
        XCTAssertEqual(underlyingDisks(of: "disk3", stores: stores), ["disk0"])
        XCTAssertEqual(underlyingDisks(of: "disk22", stores: stores), ["disk21"])
        XCTAssertEqual(underlyingDisks(of: "disk20", stores: stores), ["disk20"])
    }

    // MARK: - The cross-check

    private func attribution(_ disks: [PhysicalDisk], virtualMembers: Bool = false) -> MountAttribution {
        MountAttribution(disks: disks,
                         containerStores: ["disk1": ["disk0"], "disk2": ["disk0"], "disk3": ["disk0"],
                                           "disk5": ["disk4"], "disk22": ["disk21"]],
                         bootDisks: ["disk3", "disk0"],
                         hostsVirtualMembers: virtualMembers)
    }

    private func bottomDrawer(mounted: Bool) -> PhysicalDisk {
        var disk = PhysicalDisk(device: "disk21")
        disk.containers = [Container(device: "disk22", physicalStore: "disk21s2", volumes: [
            volume("disk22s1", " Bottom Drawer", at: mounted ? "/Volumes/ Bottom Drawer" : nil,
                   uuid: Tower.bottomDrawer)])]
        return disk
    }

    func testWholeDiskStickDiscoveryMissedIsUnaccounted() {
        // Discovery listed disk20 and found no volume on it, the way it did
        // before it read the whole-disk entry. The kernel knows better.
        let found = unaccountedMounts(
            [KernelMount(source: "/dev/disk20", mountPoint: "/Volumes/STICK")],
            attribution: attribution([PhysicalDisk(device: "disk20")]),
            origin: { _ in .unknown })
        XCTAssertEqual(found, [UnaccountedMount(device: "disk20", mountPoint: "/Volumes/STICK",
                                                why: .onDiscoveredDisk)])
    }

    func testVolumeDiscoveryListedAsMountedIsAccountedFor() {
        let found = unaccountedMounts(
            [KernelMount(source: "/dev/disk22s1", mountPoint: "/Volumes/ Bottom Drawer")],
            attribution: attribution([bottomDrawer(mounted: true)]),
            origin: { _ in .unknown })
        XCTAssertEqual(found, [])
    }

    func testMountDiscoveryCalledUnmountedIsUnaccounted() {
        let found = unaccountedMounts(
            [KernelMount(source: "com.apple.TimeMachine.local@/dev/disk22s1",
                         mountPoint: "/Volumes/.timemachine/snap")],
            attribution: attribution([bottomDrawer(mounted: false)]),
            origin: { _ in .unknown })
        XCTAssertEqual(found.map(\.why), [.onDiscoveredDisk])
    }

    func testRAIDSetNobodyCanPlaceIsUnattributed() {
        let found = unaccountedMounts(
            [KernelMount(source: "/dev/disk30", mountPoint: "/Volumes/RAID")],
            attribution: attribution([bottomDrawer(mounted: false)]),
            origin: { _ in .unknown })
        XCTAssertEqual(found, [UnaccountedMount(device: "disk30", mountPoint: "/Volumes/RAID",
                                                why: .unattributed)])
    }

    func testInternalIsNoAlibiWhenTheTowerCarriesRAIDMembers() {
        let mounts = [KernelMount(source: "/dev/disk30", mountPoint: "/Volumes/RAID")]
        XCTAssertEqual(unaccountedMounts(mounts, attribution: attribution([bottomDrawer(mounted: false)]),
                                         origin: { _ in .internalDisk }), [])
        XCTAssertEqual(unaccountedMounts(mounts,
                                         attribution: attribution([bottomDrawer(mounted: false)],
                                                                  virtualMembers: true),
                                         origin: { _ in .internalDisk }).map(\.why),
                       [.unattributed])
    }

    func testThisMacsOwnMountsNeverCount() {
        let mounts = [
            KernelMount(source: "/dev/disk3s1s1", mountPoint: "/"),
            KernelMount(source: "devfs", mountPoint: "/dev"),
            KernelMount(source: "/dev/disk3s6", mountPoint: "/System/Volumes/VM"),
            KernelMount(source: "/dev/disk3s2", mountPoint: "/System/Volumes/Preboot"),
            KernelMount(source: "/dev/disk3s4", mountPoint: "/System/Volumes/Update"),
            KernelMount(source: "/dev/disk1s2", mountPoint: "/System/Volumes/xarts"),
            KernelMount(source: "/dev/disk3s5", mountPoint: "/System/Volumes/Data"),
            KernelMount(source: "/dev/disk5s1", mountPoint: "/Library/Developer/CoreSimulator/Volumes/iOS_23C54"),
            KernelMount(source: "map auto_home", mountPoint: "/System/Volumes/Data/home"),
            KernelMount(source: "/dev/disk2s1", mountPoint: "/System/Volumes/Update/SFR/mnt1"),
        ]
        var asked: [String] = []
        let found = unaccountedMounts(mounts, attribution: attribution([bottomDrawer(mounted: false)]),
                                      origin: { disk in
                                          asked.append(disk)
                                          return disk == "disk4" ? .diskImage : .unknown
                                      })
        XCTAssertEqual(found, [])
        // Only the simulator image needed asking about; everything else was
        // the startup disk.
        XCTAssertEqual(asked, ["disk4"])
    }

    func testLsofOutputNamesEachProcessOnce() {
        let text = "p97495\ncIINA\np61786\ncsleep\np97495\ncIINA\n"
        XCTAssertEqual(parseLsofBlockers(text), ["IINA (pid 97495)", "sleep (pid 61786)"])
    }
}
