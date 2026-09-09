// DiskImageMatchingTests — the parse and the match, with no hardware.
//
// The fixture below is the shape `hdiutil info -plist` actually printed on the
// tower on 2026-09-09 for a scratch image created on /Volumes/Backup: four
// system entities, only the last one mounted, and the outer whole disk two
// numbers below the synthesized APFS container inside it.
//
// The match is where "this image is in the way" is decided, and getting it
// wrong in either direction is expensive: too loose detaches an image nobody
// asked about, too tight leaves a park failing with an unactionable blocker.

import XCTest
@testable import DriveParkKit

final class DiskImageMatchingTests: XCTestCase {
    private func plist(imagePath: String) -> [String: Any] {
        ["images": [[
            "image-path": imagePath,
            "system-entities": [
                ["dev-entry": "/dev/disk12"],
                ["dev-entry": "/dev/disk12s1"],
                ["dev-entry": "/dev/disk13"],
                ["dev-entry": "/dev/disk13s1", "mount-point": "/Volumes/ParkScratch"]
            ]
        ]]]
    }

    func testParsePicksTheOuterWholeDiskNotTheContainer() {
        let images = parseAttachedImages(plist(imagePath: "/Volumes/Backup/scratch.dmg"))
        XCTAssertEqual(images.count, 1)
        // disk13 is the synthesized APFS container inside the image. Ejecting
        // it would not detach the image; disk12 is what does.
        XCTAssertEqual(images.first?.wholeDisk, "disk12")
        XCTAssertEqual(images.first?.mountedVolumes, ["disk13s1"])
    }

    func testParseKeepsTheMountPointsOfTheImagesOwnVolumes() {
        // Needed to name what is open inside a dmg that refuses to detach.
        let images = parseAttachedImages(plist(imagePath: "/Volumes/Backup/scratch.dmg"))
        XCTAssertEqual(images.first?.mountPoints, ["/Volumes/ParkScratch"])
    }

    func testParseKeepsTheBackingPathVerbatimAndResolvedSeparately() {
        let images = parseAttachedImages(plist(imagePath: "/Volumes/link/scratch.dmg")) { _ in
            "/Volumes/Backup/scratch.dmg"
        }
        XCTAssertEqual(images.first?.imagePath, "/Volumes/link/scratch.dmg")
        XCTAssertEqual(images.first?.resolvedImagePath, "/Volumes/Backup/scratch.dmg")
    }

    func testAnImageOnTheVolumeIsInTheWay() {
        let images = parseAttachedImages(plist(imagePath: "/Volumes/Backup/drivepark-scratch/scratch.dmg"))
        XCTAssertEqual(imagesBacked(byVolumeAt: "/Volumes/Backup", in: images).count, 1)
    }

    func testASiblingVolumeWithTheSamePrefixIsNotInTheWay() {
        // The bug this exists to prevent: /Volumes/Backup matching a file on
        // /Volumes/Backup2 and detaching an image that pins nothing here.
        let images = parseAttachedImages(plist(imagePath: "/Volumes/Backup2/scratch.dmg"))
        XCTAssertTrue(imagesBacked(byVolumeAt: "/Volumes/Backup", in: images).isEmpty)
    }

    func testAnImageOnTheBootDiskIsNotInTheWay() {
        let images = parseAttachedImages(plist(imagePath: "/Users/blake/Downloads/app.dmg"))
        XCTAssertTrue(imagesBacked(byVolumeAt: "/Volumes/Backup", in: images).isEmpty)
    }

    func testAVolumeNameWithALeadingSpaceStillMatches() {
        // " Bottom Drawer" is a real volume on this tower, leading space and all.
        let images = parseAttachedImages(plist(imagePath: "/Volumes/ Bottom Drawer/x.dmg"))
        XCTAssertEqual(imagesBacked(byVolumeAt: "/Volumes/ Bottom Drawer", in: images).count, 1)
    }

    func testAnEmptyMountPointMatchesNothing() {
        // Guards the prefix rule against degenerating into "" + "/" matching
        // every absolute path on the machine.
        let images = parseAttachedImages(plist(imagePath: "/Volumes/Backup/scratch.dmg"))
        XCTAssertTrue(imagesBacked(byVolumeAt: "", in: images).isEmpty)
    }

    func testAnEntryWithNoWholeDiskIsSkippedRatherThanGuessed() {
        let odd: [String: Any] = ["images": [[
            "image-path": "/Volumes/Backup/weird.dmg",
            "system-entities": [["dev-entry": "/dev/disk14s1"]]
        ]]]
        XCTAssertTrue(parseAttachedImages(odd).isEmpty)
    }
}
