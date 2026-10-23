import XCTest
@testable import PassthroughCore

final class ShellEndedSessionsTests: XCTestCase {
    private func info(_ id: String, running: Bool, exit: Int32? = nil) -> ShellSessionInfo {
        ShellSessionInfo(id: id, title: id, startedAt: 0, lastOutputAt: 0, running: running, exitStatus: exit)
    }

    func testEndedMessageMakesSessionReadOnly() {
        var ended = ShellEndedSessions()
        XCTAssertTrue(ended.isWritable("a"))
        ended.ended("a", exitStatus: 0)
        XCTAssertTrue(ended.isEnded("a"))
        XCTAssertFalse(ended.isWritable("a"))
        XCTAssertTrue(ended.isWritable("b"))
        XCTAssertEqual(ended.exitStatus("a"), 0)
    }

    func testNothingShownIsWritable() {
        XCTAssertTrue(ShellEndedSessions().isWritable(nil))
    }

    func testClosedTabIsNotWritable() {
        var ended = ShellEndedSessions()
        XCTAssertTrue(ended.isWritable("a", openTabs: ["a"]))
        XCTAssertFalse(ended.isWritable("a", openTabs: []))
        XCTAssertTrue(ended.isWritable(nil, openTabs: []))
        ended.ended("a", exitStatus: 0)
        XCTAssertFalse(ended.isWritable("a", openTabs: ["a"]))
    }

    func testNegativeStatusMeansNone() {
        var ended = ShellEndedSessions()
        ended.ended("a", exitStatus: -1)
        XCTAssertTrue(ended.isEnded("a"))
        XCTAssertNil(ended.exitStatus("a"))
        XCTAssertEqual(ended.banner("a"), "Session closed — read-only")
    }

    func testMessageWithoutStatusKeepsKnownStatus() {
        var ended = ShellEndedSessions()
        ended.apply([info("a", running: false, exit: 3)])
        ended.ended("a", exitStatus: -1)
        XCTAssertEqual(ended.exitStatus("a"), 3)
    }

    func testListMarksStoppedSessionsEnded() {
        var ended = ShellEndedSessions()
        ended.apply([info("a", running: true), info("b", running: false, exit: 130), info("c", running: false)])
        XCTAssertFalse(ended.isEnded("a"))
        XCTAssertEqual(ended.exitStatus("b"), 130)
        XCTAssertTrue(ended.isEnded("c"))
        XCTAssertNil(ended.exitStatus("c"))
    }

    func testUnlistedSessionsAreForgottenUnlessKept() {
        var ended = ShellEndedSessions()
        ended.ended("a", exitStatus: 0)
        ended.ended("b", exitStatus: 1)
        ended.apply([], keeping: ["b"])
        XCTAssertFalse(ended.isEnded("a"))
        XCTAssertTrue(ended.isEnded("b"))
    }

    func testForget() {
        var ended = ShellEndedSessions()
        ended.ended("a", exitStatus: 0)
        ended.forget("a")
        XCTAssertFalse(ended.isEnded("a"))
    }

    func testBannerText() {
        XCTAssertEqual(ShellEndedSessions.banner(exitStatus: 0), "Session ended (exit 0) — read-only")
        XCTAssertEqual(ShellEndedSessions.banner(exitStatus: 127), "Session ended (exit 127) — read-only")
        XCTAssertEqual(ShellEndedSessions.banner(exitStatus: nil), "Session closed — read-only")
        var ended = ShellEndedSessions()
        XCTAssertNil(ended.banner("a"))
        ended.ended("a", exitStatus: 2)
        XCTAssertEqual(ended.banner("a"), "Session ended (exit 2) — read-only")
    }
}
