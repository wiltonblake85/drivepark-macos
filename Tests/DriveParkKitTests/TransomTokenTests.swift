// TransomTokenTests: an unattended CLI never asks the Keychain for the Transom
// token, because the login keychain answers a new binary with a dialog that
// nobody is there to dismiss (SPEC section 10, 2026-10-10).

import XCTest
@testable import DriveParkKit

final class TransomTokenTests: XCTestCase {

    func testWithNoOneToAnswerTheKeychainIsNeverAsked() {
        var asked = 0
        let picked = Transom.pickToken(environment: nil, mayReadKeychain: false,
                                       keychain: { asked += 1; return "stored-token" })
        XCTAssertNil(picked)
        XCTAssertEqual(asked, 0)
    }

    func testTheEnvironmentStillWorksUnattended() {
        var asked = 0
        let picked = Transom.pickToken(environment: "from-a-script", mayReadKeychain: false,
                                       keychain: { asked += 1; return "stored-token" })
        XCTAssertEqual(picked?.token, "from-a-script")
        XCTAssertEqual(picked?.source, "environment")
        XCTAssertEqual(asked, 0)
    }

    func testTheEnvironmentWinsOverTheKeychain() {
        var asked = 0
        let picked = Transom.pickToken(environment: "from-a-script", mayReadKeychain: true,
                                       keychain: { asked += 1; return "stored-token" })
        XCTAssertEqual(picked?.token, "from-a-script")
        XCTAssertEqual(asked, 0)
    }

    func testAttendedTheKeychainIsUsed() {
        let picked = Transom.pickToken(environment: "", mayReadKeychain: true,
                                       keychain: { "stored-token" })
        XCTAssertEqual(picked?.token, "stored-token")
        XCTAssertEqual(picked?.source, "keychain")
    }

    func testNothingStoredMeansNoToken() {
        XCTAssertNil(Transom.pickToken(environment: nil, mayReadKeychain: true, keychain: { nil }))
    }
}
