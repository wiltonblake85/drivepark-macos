// VetoHolderTests.swift: a holder record names one process, not one pid.
//
// The decision is tested with a stand-in for the kernel, so no test reads or
// writes the veto record in this Mac's preferences.

import XCTest
@testable import DriveParkKit

final class VetoHolderTests: XCTestCase {
    private let started = 1_791_280_000.123456

    private func kernel(_ table: [pid_t: ProcessIdentity]) -> (pid_t) -> ProcessIdentity? {
        { table[$0] }
    }

    func testTheProcessThatWroteTheRecordIsAlive() {
        let lookup = kernel([4242: ProcessIdentity(start: started, name: "DrivePark")])
        XCTAssertTrue(VetoBroker.holderIsAlive(pid: 4242, recordedStart: started,
                                               recordedName: "DrivePark", lookup: lookup))
    }

    /// The app crashed and the pid went to something else. kill(pid, 0)
    /// said alive, and the stale veto record never cleared.
    func testAReusedPidIsNotTheHolder() {
        let lookup = kernel([4242: ProcessIdentity(start: started + 3_600, name: "DrivePark")])
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: 4242, recordedStart: started,
                                                recordedName: "DrivePark", lookup: lookup))
    }

    /// A root-owned process answers kill(pid, 0) with EPERM, which the old
    /// check read as alive. The start time decides it instead.
    func testARootOwnedProcessOnTheSamePidIsNotTheHolder() {
        let lookup = kernel([88: ProcessIdentity(start: started - 86_400, name: "mds_stores")])
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: 88, recordedStart: started,
                                                recordedName: "DrivePark", lookup: lookup))
    }

    func testNoProcessOnThePidIsNotTheHolder() {
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: 4242, recordedStart: started,
                                                recordedName: "DrivePark", lookup: kernel([:])))
    }

    /// Written by a build before start times were recorded: the kernel's name
    /// for the process has to match instead.
    func testARecordWithoutAStartTimeFallsBackToTheName() {
        let lookup = kernel([4242: ProcessIdentity(start: started, name: "DrivePark"),
                             4343: ProcessIdentity(start: started, name: "Safari")])
        XCTAssertTrue(VetoBroker.holderIsAlive(pid: 4242, recordedStart: nil,
                                               recordedName: "DrivePark", lookup: lookup))
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: 4343, recordedStart: nil,
                                                recordedName: "DrivePark", lookup: lookup))
    }

    /// The real kernel read: this process is found, the same twice, and
    /// launchd (pid 1, owned by root) is readable too, which is the case
    /// kill(pid, 0) could not judge.
    func testTheKernelAnswersForThisProcessAndForRoot() throws {
        let me = try XCTUnwrap(ProcessIdentity.of(getpid()))
        XCTAssertEqual(ProcessIdentity.of(getpid()), me)
        XCTAssertLessThanOrEqual(me.start, Date().timeIntervalSince1970)
        XCTAssertFalse(me.name.isEmpty)
        let launchd = try XCTUnwrap(ProcessIdentity.of(1))
        XCTAssertLessThan(launchd.start, me.start)
        XCTAssertTrue(VetoBroker.holderIsAlive(pid: getpid(), recordedStart: me.start,
                                               recordedName: me.name, lookup: ProcessIdentity.of))
        XCTAssertFalse(VetoBroker.holderIsAlive(pid: 1, recordedStart: me.start,
                                                recordedName: "DrivePark", lookup: ProcessIdentity.of))
    }
}
