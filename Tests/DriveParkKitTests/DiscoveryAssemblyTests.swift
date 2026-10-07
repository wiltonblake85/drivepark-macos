// DiscoveryAssemblyTests: discovery from diskutil's answers, with no disks.
//
// The plists are shaped on the ones captured on this Mac on 2026-10-06: the
// tower's bays, the startup disk's containers, and a partitionless exFAT
// image (Content "", MountPoint and VolumeName on the whole-disk entry, no
// Partitions, no VolumeUUID). The Mac in them has been moved onto an external
// SSD, disk4, which is the case that had nothing keeping it out (audit H3).

import XCTest
@testable import DriveParkKit

final class DiscoveryAssemblyTests: XCTestCase {

    /// External physical: the boot SSD, an exFAT stick and Bottom Drawer.
    private let physicalList: [String: Any] = ["WholeDisks": ["disk4", "disk20", "disk21"]]

    private var fullList: [String: Any] {
        ["AllDisksAndPartitions": [
            // The external startup disk.
            ["Content": "GUID_partition_scheme", "DeviceIdentifier": "disk4", "Partitions": [
                ["Content": "Apple_APFS_ISC", "DeviceIdentifier": "disk4s1"],
                ["Content": "Apple_APFS", "DeviceIdentifier": "disk4s2"],
                ["Content": "Apple_APFS_Recovery", "DeviceIdentifier": "disk4s3"],
            ]],
            ["Content": "Apple_APFS_Container", "DeviceIdentifier": "disk5",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk4s2"]],
             "Partitions": [] as [Any],
             "APFSVolumes": [
                ["DeviceIdentifier": "disk5s1", "VolumeName": "Macintosh HD",
                 "MountPoint": "/System/Volumes/Update/mnt1", "VolumeUUID": "AAAA0001-0000-0000-0000-000000000001"],
                ["DeviceIdentifier": "disk5s1s1", "VolumeName": "Macintosh HD",
                 "MountPoint": "/", "VolumeUUID": "AAAA0001-0000-0000-0000-000000000002"],
                ["DeviceIdentifier": "disk5s2", "VolumeName": "Preboot",
                 "MountPoint": "/System/Volumes/Preboot", "VolumeUUID": "AAAA0001-0000-0000-0000-000000000003"],
                ["DeviceIdentifier": "disk5s4", "VolumeName": "Update",
                 "VolumeUUID": "AAAA0001-0000-0000-0000-000000000004"],
                ["DeviceIdentifier": "disk5s5", "VolumeName": "Data",
                 "MountPoint": "/System/Volumes/Data", "VolumeUUID": "AAAA0001-0000-0000-0000-000000000005"],
             ]],
            // The partitionless exFAT stick, exactly as captured.
            ["Content": "", "DeviceIdentifier": "disk20", "MountPoint": "/Volumes/DPSTICK",
             "OSInternal": false, "Size": 67108864, "VolumeName": "DPSTICK"],
            // Bottom Drawer, with a leftover Microsoft Reserved partition.
            ["Content": "GUID_partition_scheme", "DeviceIdentifier": "disk21", "Partitions": [
                ["Content": "Microsoft Reserved", "DeviceIdentifier": "disk21s1"],
                ["Content": "Apple_APFS", "DeviceIdentifier": "disk21s2"],
            ]],
            ["Content": "Apple_APFS_Container", "DeviceIdentifier": "disk22",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk21s2"]],
             "Partitions": [] as [Any],
             "APFSVolumes": [
                ["DeviceIdentifier": "disk22s1", "VolumeName": " Bottom Drawer",
                 "MountPoint": "/Volumes/ Bottom Drawer", "VolumeUUID": "C79BDC4E-55A9-48CE-BE31-DAE64C36BC15"],
                // A bootable backup's plumbing. Never a drive.
                ["DeviceIdentifier": "disk22s2", "VolumeName": "Preboot",
                 "VolumeUUID": "BBBB0001-0000-0000-0000-000000000002"],
                ["DeviceIdentifier": "disk22s3", "VolumeName": "Recovery",
                 "VolumeUUID": "BBBB0001-0000-0000-0000-000000000003"],
             ]],
        ]]
    }

    /// `diskutil info -plist /` on a Mac booted from disk4.
    private let bootInfo: [String: Any] = [
        "DeviceIdentifier": "disk5s1s1",
        "ParentWholeDisk": "disk5",
        "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]],
        "MountPoint": "/",
    ]

    private let roles: [String: [String]] = [
        "disk5s1": ["System"], "disk5s2": ["Preboot"], "disk5s4": ["Update"], "disk5s5": ["Data"],
        "disk22s2": ["Preboot"], "disk22s3": ["Recovery"],
    ]

    private func info(_ device: String) -> PlistRead {
        .plist(["MediaName": "TDAS", "BusProtocol": "USB", "TotalSize": 4_000_787_030_016])
    }

    private func assemble(boot: Set<String>,
                          info: ((String) -> PlistRead)? = nil) -> AssembledDisks {
        assembleDisks(physicalList: physicalList, wideList: nil, fullList: fullList,
                      bootDisks: boot, info: info ?? self.info,
                      roles: { self.roles[$0] ?? [] }, imageBackingPath: { _ in nil })
    }

    private var boot: Set<String> {
        bootDisks(bootInfo: bootInfo, mounts: [], stores: containerStores(in: fullList))
    }

    func testDiskBehindTheRunningSystemIsFound() {
        XCTAssertEqual(boot, ["disk4", "disk5"])
    }

    func testRunningSystemFoundFromTheKernelEvenWithoutDiskutil() {
        // Belt and braces: whatever holds /System/Volumes/Data is the system.
        let fromMounts = bootDisks(bootInfo: [:],
                                   mounts: [KernelMount(source: "/dev/disk5s5", mountPoint: "/System/Volumes/Data")],
                                   stores: containerStores(in: fullList))
        XCTAssertEqual(fromMounts, ["disk4", "disk5"])
    }

    func testExternalStartupDiskIsNeverADrive() {
        let disks = assemble(boot: boot).disks
        XCTAssertEqual(disks.map(\.device), ["disk20", "disk21"])
        XCTAssertFalse(disks.flatMap(\.allVolumes).contains { $0.device.hasPrefix("disk5") })
    }

    func testRunningSystemsVolumesAreRefusedEvenIfTheDiskGetsIn() {
        // Suppose the boot lookup were wrong and disk4 got in anyway. "/" and
        // /System/Volumes still never become volumes, and the roles keep
        // Preboot and Update out.
        let disks = assemble(boot: []).disks
        let names = disks.flatMap(\.allVolumes).map(\.name)
        let points = disks.flatMap(\.allVolumes).compactMap(\.mountPoint)
        XCTAssertFalse(points.contains("/"))
        XCTAssertFalse(points.contains { $0.hasPrefix("/System/Volumes/") })
        XCTAssertFalse(names.contains("Preboot"))
        XCTAssertFalse(names.contains("Update"))
    }

    func testPartitionlessStickIsFound() {
        let stick = assemble(boot: boot).disks.first { $0.device == "disk20" }
        XCTAssertEqual(stick?.allVolumes, [Volume(device: "disk20", name: "DPSTICK",
                                                  mountPoint: "/Volumes/DPSTICK", uuid: nil)])
    }

    func testStickUUIDIsFilledInFromDiskutilInfo() {
        // The list left it out; `diskutil info` had it, captured 2026-10-06.
        let assembled = assemble(boot: boot, info: { device in
            device == "disk20"
                ? .plist(["VolumeName": "DPSTICK", "VolumeUUID": "E984B669-8189-3EB0-B59C-324AF2494103"])
                : self.info(device)
        })
        XCTAssertTrue(assembled.problems.isEmpty)
        XCTAssertEqual(assembled.disks.first { $0.device == "disk20" }?.allVolumes.first?.uuid,
                       "e984b669-8189-3eb0-b59c-324af2494103")
    }

    func testStickWhoseInfoStallsMakesTheReadIncomplete() {
        let assembled = assemble(boot: boot, info: { device in
            device == "disk20"
                ? .failed(reason: "diskutil info -plist disk20 did not answer in 10s", timedOut: true)
                : self.info(device)
        })
        XCTAssertTrue(assembled.timedOut)
        XCTAssertFalse(assembled.problems.isEmpty)
    }

    func testSystemRoleVolumesOnAnExternalDiskAreSkipped() {
        let bottom = assemble(boot: boot).disks.first { $0.device == "disk21" }
        XCTAssertEqual(bottom?.allVolumes.map(\.device), ["disk22s1"])
        XCTAssertEqual(bottom?.allVolumes.first?.uuid, Tower.bottomDrawer)
    }

    func testInfoThatTimesOutMakesTheReadIncomplete() {
        let assembled = assemble(boot: boot, info: { device in
            device == "disk21"
                ? .failed(reason: "diskutil info -plist disk21 did not answer in 10s", timedOut: true)
                : self.info(device)
        })
        XCTAssertTrue(assembled.timedOut)
        XCTAssertEqual(assembled.problems, ["diskutil info -plist disk21 did not answer in 10s"])
        // Still listed, for display, and marked as not answering.
        XCTAssertEqual(assembled.disks.first { $0.device == "disk21" }?.infoAnswered, false)
    }

    func testRAIDMemberOnTheTowerIsNoticed() {
        var list = fullList
        var entries = list["AllDisksAndPartitions"] as! [[String: Any]]
        entries[3] = ["Content": "GUID_partition_scheme", "DeviceIdentifier": "disk21", "Partitions": [
            ["Content": "Apple_RAID", "DeviceIdentifier": "disk21s2"]]]
        list["AllDisksAndPartitions"] = entries
        let assembled = assembleDisks(physicalList: physicalList, wideList: nil, fullList: list,
                                      bootDisks: boot, info: info, roles: { _ in [] },
                                      imageBackingPath: { _ in nil })
        XCTAssertTrue(assembled.hostsVirtualMembers)
        XCTAssertFalse(assemble(boot: boot).hostsVirtualMembers)
    }

    func testListWithoutWholeDisksIsAProblemNotAnEmptyTower() {
        let assembled = assembleDisks(physicalList: [:], wideList: nil, fullList: fullList,
                                      bootDisks: [], info: info, roles: { _ in [] },
                                      imageBackingPath: { _ in nil })
        XCTAssertFalse(assembled.problems.isEmpty)
    }
}
