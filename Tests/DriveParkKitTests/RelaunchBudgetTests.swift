// RelaunchBudgetTests.swift: the watchdog stops on a crash loop, and says so.

import XCTest
@testable import DriveParkKit

final class RelaunchBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_280_000)

    func testFourDeathsInTenMinutesAreEachRelaunched() {
        var budget = RelaunchBudget()
        for minute in 0..<4 {
            XCTAssertTrue(budget.noteDeath(at: start.addingTimeInterval(Double(minute) * 60)))
        }
        XCTAssertFalse(budget.exhausted)
    }

    /// It used to back off for a minute and start again, forever.
    func testTheFifthDeathInTenMinutesStopsItForGood() {
        var budget = RelaunchBudget()
        for second in 0..<4 { _ = budget.noteDeath(at: start.addingTimeInterval(Double(second))) }
        XCTAssertFalse(budget.noteDeath(at: start.addingTimeInterval(5)))
        XCTAssertTrue(budget.exhausted)
        XCTAssertFalse(budget.noteDeath(at: start.addingTimeInterval(3_600)),
                       "an hour later is still a crash loop nobody has looked at")
    }

    func testDeathsSpreadOverMoreThanTenMinutesKeepBeingRelaunched() {
        var budget = RelaunchBudget()
        for step in 0..<12 {
            XCTAssertTrue(budget.noteDeath(at: start.addingTimeInterval(Double(step) * 151)))
        }
    }

    func testAPersonStartingTheAppResetsIt() {
        var budget = RelaunchBudget()
        for second in 0..<5 { _ = budget.noteDeath(at: start.addingTimeInterval(Double(second))) }
        XCTAssertTrue(budget.exhausted)
        budget.reset()
        XCTAssertTrue(budget.noteDeath(at: start.addingTimeInterval(10)))
    }
}
