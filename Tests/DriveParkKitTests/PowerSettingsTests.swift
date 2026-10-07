// PowerSettingsTests.swift: the idle sleep setting without launching pmset.

import XCTest
@testable import DriveParkKit

final class PowerSettingsTests: XCTestCase {
    /// The IOKit read replaced a pmset launch on every refresh. It has to give
    /// the same answer pmset prints, or the sleep trigger's warning would
    /// start saying something new about the same Mac.
    func testIOKitReadAgreesWithPmset() throws {
        let fromIOKit = PowerSettings.idleSleepMinutesFromIOKit()
        let fromPmset = PowerSettings.idleSleepMinutesFromPmset()
        guard let fromIOKit, let fromPmset else {
            throw XCTSkip("one of the two reads is unavailable on this Mac")
        }
        XCTAssertEqual(fromIOKit, fromPmset)
    }
}
