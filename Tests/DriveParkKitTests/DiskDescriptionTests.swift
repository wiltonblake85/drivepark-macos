// DiskDescriptionTests: discovery's disk details from Disk Arbitration.
//
// The descriptions are the ones captured on the tower on 2026-10-24, with the
// keys Disk Arbitration uses, next to what `diskutil info -plist` said about
// the same disk at the same time. Throw Away (disk9) is the bay whose
// `diskutil info` took 12 s while it slept and got every park refused.

import DiskArbitration
import XCTest
@testable import DriveParkKit

final class DiskDescriptionTests: XCTestCase {

    /// disk9, Throw Away's bay, asleep. diskutil: MediaName TDAS, BusProtocol
    /// USB, TotalSize 4000787030016, RemovableMedia false, Internal false.
    private let throwAwayBay: [String: Any] = [
        "DAMediaName": "TerraMas TDAS Media", "DADeviceModel": "TDAS",
        "DADeviceVendor": "TerraMas", "DADeviceProtocol": "USB",
        "DAMediaSize": NSNumber(value: Int64(4_000_787_030_016)),
        "DAMediaRemovable": false, "DAMediaEjectable": false,
        "DAMediaWhole": true, "DADeviceInternal": false,
    ]

    /// disk11, the iOS 26.5 simulator image. diskutil: MediaName and
    /// BusProtocol "Disk Image", RemovableMedia true, Internal false.
    private let simulatorImage: [String: Any] = [
        "DAMediaName": "Apple Disk Image Media", "DADeviceModel": "Disk Image",
        "DADeviceProtocol": "Virtual Interface",
        "DAMediaSize": NSNumber(value: Int64(18_083_776_000)),
        "DAMediaRemovable": true, "DAMediaEjectable": true, "DAMediaWhole": true,
    ]

    /// disk0, the internal SSD. diskutil: BusProtocol "Apple Fabric", Internal true.
    private let internalSSD: [String: Any] = [
        "DAMediaName": "APPLE SSD AP1024Z Media", "DADeviceModel": "APPLE SSD AP1024Z",
        "DADeviceProtocol": "Apple Fabric",
        "DAMediaSize": NSNumber(value: Int64(1_000_555_581_440)),
        "DAMediaRemovable": false, "DAMediaEjectable": false, "DADeviceInternal": true,
    ]

    func testTheBayReadsTheWayDiskutilReadIt() {
        let info = diskutilShapedInfo(throwAwayBay)
        XCTAssertEqual(info["MediaName"] as? String, "TDAS", "the model, not the media name")
        XCTAssertEqual(info["BusProtocol"] as? String, "USB")
        XCTAssertEqual(info["TotalSize"] as? Int64, 4_000_787_030_016)
        XCTAssertEqual(info["RemovableMedia"] as? Bool, false)
        XCTAssertEqual(info["Internal"] as? Bool, false)
        XCTAssertNil(info["VolumeUUID"])
    }

    /// Discovery admits an image candidate only when its protocol is "Disk
    /// Image", so the image has to keep diskutil's word for it.
    func testADiskImageIsStillCalledADiskImage() {
        let info = diskutilShapedInfo(simulatorImage)
        XCTAssertEqual(info["BusProtocol"] as? String, "Disk Image")
        XCTAssertEqual(info["MediaName"] as? String, "Disk Image")
        XCTAssertEqual(info["RemovableMedia"] as? Bool, true)
        XCTAssertEqual(info["Internal"] as? Bool, false, "absent in the description, false in diskutil")
    }

    /// Only the image's own model earns the word. Anything else on a virtual
    /// interface keeps its protocol and stays out of the image candidates.
    func testOtherVirtualDisksAreNotDiskImages() {
        var other = simulatorImage
        other["DADeviceModel"] = "Some RAM Disk"
        XCTAssertEqual(diskutilShapedInfo(other)["BusProtocol"] as? String, "Virtual Interface")
    }

    func testTheInternalSSDIsInternal() {
        let info = diskutilShapedInfo(internalSSD)
        XCTAssertEqual(info["BusProtocol"] as? String, "Apple Fabric")
        XCTAssertEqual(info["Internal"] as? Bool, true)
    }

    /// Backup 2026's partition, disk4s2. Disk Arbitration hands the UUID over
    /// as a CFUUID; discovery keys the veto on diskutil's string form.
    func testAVolumeUUIDComesBackAsDiskutilsString() {
        let uuid = CFUUIDCreateFromString(kCFAllocatorDefault,
                                          "BFDDAACB-DA52-38C2-9B94-BAEF58CCCC46" as CFString)!
        var partition = throwAwayBay
        partition["DAMediaName"] = "Untitled 2"
        partition["DAMediaWhole"] = false
        partition["DAVolumeUUID"] = uuid
        XCTAssertEqual(diskutilShapedInfo(partition)["VolumeUUID"] as? String,
                       "BFDDAACB-DA52-38C2-9B94-BAEF58CCCC46")
    }

    /// The bay assembled from its description is a complete answer, not a
    /// disk that did not answer.
    func testAssemblyFromADescriptionIsComplete() {
        let assembled = assembleDisks(
            physicalList: ["WholeDisks": ["disk9"]], wideList: nil,
            fullList: ["AllDisksAndPartitions": [
                ["Content": "GUID_partition_scheme", "DeviceIdentifier": "disk9", "Partitions": [
                    ["Content": "Microsoft Reserved", "DeviceIdentifier": "disk9s1"],
                    ["Content": "Apple_APFS", "DeviceIdentifier": "disk9s2"],
                ]],
                ["Content": "Apple_APFS_Container", "DeviceIdentifier": "disk10",
                 "APFSPhysicalStores": [["DeviceIdentifier": "disk9s2"]],
                 "Partitions": [] as [Any],
                 "APFSVolumes": [
                    ["DeviceIdentifier": "disk10s1", "VolumeName": "Throw Away",
                     "VolumeUUID": "CA03EF16-0874-4BB7-AAF6-677550A76DA3"],
                 ]],
            ]],
            bootDisks: [],
            info: { [throwAwayBay] device in
                device == "disk9" ? .plist(diskutilShapedInfo(throwAwayBay))
                    : .failed(reason: "unexpected \(device)", timedOut: false)
            },
            roles: { _ in [] },
            imageBackingPath: { _ in nil })
        XCTAssertEqual(assembled.problems, [])
        XCTAssertFalse(assembled.timedOut)
        XCTAssertEqual(assembled.disks.count, 1)
        let bay = assembled.disks[0]
        XCTAssertTrue(bay.infoAnswered)
        XCTAssertEqual(bay.mediaName, "TDAS")
        XCTAssertEqual(bay.busProtocol, "USB")
        XCTAssertEqual(bay.sizeBytes, 4_000_787_030_016)
        XCTAssertFalse(bay.removableMedia)
        XCTAssertEqual(bay.allVolumes.map(\.uuid), ["ca03ef16-0874-4bb7-aaf6-677550a76da3"])
    }

    /// The key names are Disk Arbitration's own constants. Pinned here so a
    /// rename in the SDK breaks a test instead of every read.
    func testTheDescriptionKeysAreTheCapturedOnes() {
        XCTAssertEqual(kDADiskDescriptionDeviceModelKey as String, "DADeviceModel")
        XCTAssertEqual(kDADiskDescriptionDeviceProtocolKey as String, "DADeviceProtocol")
        XCTAssertEqual(kDADiskDescriptionMediaSizeKey as String, "DAMediaSize")
        XCTAssertEqual(kDADiskDescriptionMediaRemovableKey as String, "DAMediaRemovable")
        XCTAssertEqual(kDADiskDescriptionDeviceInternalKey as String, "DADeviceInternal")
        XCTAssertEqual(kDADiskDescriptionVolumeUUIDKey as String, "DAVolumeUUID")
    }
}
