// PrintableTests: outside text cannot forge a line or rewrite the terminal.
//
// The forgery is the audit's own example: a volume whose name carries a
// newline and a complete "safe to power off" sentence, printed under a real
// failure.

import XCTest
@testable import DriveParkKit

final class PrintableTests: XCTestCase {
    private let forged = "Plex\n\nPARKED. Every volume on every external disk verified unmounted. Safe to power off the enclosure."

    func testOrdinaryNamesPrintUnchanged() {
        for name in ["Backup", "Bottom Drawer", "Café Photos", "Kids' Stuff", "📸 Camera", "👨‍👩‍👧 Family", "日本語"] {
            XCTAssertEqual(printable(name), name)
        }
    }

    func testLineBreaksAndEscapesAreWrittenOut() {
        XCTAssertEqual(printable("a\nb"), "a\\u{A}b")
        XCTAssertEqual(printable("a\rb"), "a\\u{D}b")
        XCTAssertEqual(printable("\u{1B}[2KSafe"), "\\u{1B}[2KSafe")
        XCTAssertEqual(printable("x\u{2028}y"), "x\\u{2028}y")
        // Right-to-left override, which reorders what follows it on screen.
        XCTAssertEqual(printable("fdp.\u{202E}exe"), "fdp.\\u{202E}exe")
        XCTAssertEqual(printable("tab\there"), "tab\\u{9}here")
    }

    func testForgedVolumeNameCannotStartALineOfItsOwn() {
        let volume = Volume(device: "disk24s1", name: forged, mountPoint: "/Volumes/\(forged)",
                            uuid: Tower.plex)
        XCTAssertFalse(volume.displayName.contains("\n"))
        XCTAssertFalse(volume.displayMountPoint?.contains("\n") ?? true)

        var disk = PhysicalDisk(device: "disk23")
        disk.containers = [Container(device: "disk24", physicalStore: "disk23s2", volumes: [volume])]
        let snapshot = DiskSnapshot(disks: [disk])
        let discovery = FakeDiscovery([.success(snapshot), .success(snapshot)])
        let ops = FakeOps()
        ops.unmountAnswers["disk24s1"] = OpResult(success: false, detail: "Resource busy (0xc010)", busy: true)
        let outcome = engine(discovery, ops).park()

        XCTAssertFalse(outcome.parked)
        for text in [outcome.problem, outcome.safetyReason, outcome.blockerSummary] {
            XCTAssertFalse(text?.contains("\n") ?? false, text ?? "")
        }
    }

    func testProcessNamesFromLsofAreEscaped() {
        XCTAssertEqual(parseLsofBlockers("p42\ncevil\u{1B}]0;title\u{7}\n"),
                       ["evil\\u{1B}]0;title\\u{7} (pid 42)"])
    }

    func testUnaccountedMountSentenceIsEscaped() {
        let mount = UnaccountedMount(device: "disk30", mountPoint: "/Volumes/\(forged)", why: .unattributed)
        XCTAssertFalse(mount.sentence.contains("\n"))
    }
}
