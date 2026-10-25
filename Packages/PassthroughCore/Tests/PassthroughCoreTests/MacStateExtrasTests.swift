import XCTest
@testable import PassthroughCore

final class MacStateExtrasTests: XCTestCase {
    /// Anything but off counts as up: a failed VPN still holds its block, so turning it off lowers protection.
    func testVPNUp() {
        XCTAssertFalse(MacState(vpn: MacState.vpnOff).vpnUp)
        XCTAssertFalse(MacState().vpnUp, "no VPN set up")
        for state in [MacState.vpnOn, MacState.vpnConnecting, MacState.vpnFailed] {
            XCTAssertTrue(MacState(vpn: state).vpnUp, state)
        }
    }

    func testHasLid() {
        XCTAssertTrue(MacState(battery: 0.5).hasLid)
        XCTAssertFalse(MacState().hasLid, "a desktop Mac has no battery")
    }

    func testFormat() {
        XCTAssertEqual(MacFormat.duration(minutes: 190), "3 h 10 m")
        XCTAssertEqual(MacFormat.duration(minutes: 45), "45 m")
        XCTAssertEqual(MacFormat.percent(0.825), "83%")
    }

    func testAsking() {
        XCTAssertTrue(ShellSessionInfo(id: "a", title: "claude", startedAt: 0, lastOutputAt: 0, running: true, waiting: "Edit?").isAsking)
        XCTAssertFalse(ShellSessionInfo(id: "a", title: "claude", startedAt: 0, lastOutputAt: 0, running: false, waiting: "Edit?").isAsking)
        XCTAssertFalse(ShellSessionInfo(id: "a", title: "zsh", startedAt: 0, lastOutputAt: 0, running: true).isAsking)
    }

    /// macOS's time to empty, scaled to Keep awake's limit and rounded to 5.
    func testMinutesLeftToTheLimit() {
        XCTAssertEqual(MacState.minutesLeft(percent: 64, toEmpty: 300, floor: 20), 205)   // 300 × 44/64 = 206.25
        XCTAssertEqual(MacState.minutesLeft(percent: 50, toEmpty: 120, floor: 0), 120)
        XCTAssertNil(MacState.minutesLeft(percent: 20, toEmpty: 60, floor: 20), "at the limit")
        XCTAssertNil(MacState.minutesLeft(percent: 15, toEmpty: 60, floor: 20), "under it")
        XCTAssertNil(MacState.minutesLeft(percent: 0, toEmpty: 0, floor: 0))
    }
}
