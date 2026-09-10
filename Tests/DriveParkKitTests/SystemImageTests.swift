// SystemImageTests — which disk images are the system's, not a drive.
//
// Paths are the ones captured on the tower 2026-09-10, when Xcode had eight
// simulator runtimes attached and every park with images on failed on them.
// Too loose here hides a .dmg a person opened; too tight puts the simulators
// back in the safe-to-unplug answer.

import XCTest
@testable import DriveParkKit

final class SystemImageTests: XCTestCase {
    func testSimulatorRuntimeIsSystemByBackingPath() {
        XCTAssertTrue(isSystemManagedImage(
            backingPath: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/e4478b4b9014ff28fe3c265daca488f55a284f4c.asset/AssetData/Restore/043-87504-067.dmg",
            mountPoints: ["/Library/Developer/CoreSimulator/Volumes/iOS_23C54"]))
    }

    func testOlderRuntimeLocationIsSystem() {
        XCTAssertTrue(isSystemManagedImage(
            backingPath: "/Library/Developer/CoreSimulator/Images/iOS_17.dmg",
            mountPoints: []))
    }

    func testMountOutsideVolumesIsSystemEvenWithoutABackingPath() {
        // hdiutil did not answer. The mount point alone still decides.
        XCTAssertTrue(isSystemManagedImage(
            backingPath: nil,
            mountPoints: ["/Library/Developer/CoreSimulator/Volumes/watchOS_23T570"]))
    }

    func testDmgFromDownloadsIsAPersonsImage() {
        XCTAssertFalse(isSystemManagedImage(
            backingPath: "/Users/blake/Downloads/SlowBooksPro-macos-arm64.dmg",
            mountPoints: ["/Volumes/SlowBooks Pro"]))
    }

    func testParkedDmgWithNothingMountedStaysIn() {
        // Dropping it would hide the Mount action for an image DrivePark parked.
        XCTAssertFalse(isSystemManagedImage(
            backingPath: "/Volumes/Backup/drivepark-scratch/scratch.dmg",
            mountPoints: []))
        XCTAssertFalse(isSystemManagedImage(backingPath: nil, mountPoints: []))
    }

    func testVolumesPrefixIsNotFooledByASiblingPath() {
        // "/VolumesX/..." is not under /Volumes.
        XCTAssertTrue(isSystemManagedImage(backingPath: nil, mountPoints: ["/VolumesX/Thing"]))
    }
}
