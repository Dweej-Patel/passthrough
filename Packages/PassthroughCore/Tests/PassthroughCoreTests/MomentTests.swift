import XCTest
@testable import PassthroughCore

final class MomentTests: XCTestCase {
    func testEachMomentIsReadOffItsSwitches() {
        XCTAssertEqual(Moment.current(internet: true, awake: false, vpn: false), .desk)
        XCTAssertEqual(Moment.current(internet: true, awake: false, vpn: true), .public)
        XCTAssertEqual(Moment.current(internet: false, awake: true, vpn: false), .away)
    }

    /// Away leaves the VPN alone: stepping away on public Wi-Fi keeps it on, and never asks for Face ID.
    func testAwayHoldsWithTheVPNEitherWay() {
        XCTAssertEqual(Moment.current(internet: false, awake: true, vpn: true), .away)
        XCTAssertNil(Moment.away.switches?.vpn)
    }

    func testAnyOtherMixIsCustom() {
        XCTAssertEqual(Moment.current(internet: false, awake: false, vpn: false), .custom)
        XCTAssertEqual(Moment.current(internet: true, awake: true, vpn: false), .custom)
        XCTAssertEqual(Moment.current(internet: true, awake: true, vpn: true), .custom)
        XCTAssertEqual(Moment.current(internet: false, awake: false, vpn: true), .custom)
        XCTAssertNil(Moment.custom.switches)
        XCTAssertFalse(Moment.choices.contains(.custom), "custom is never offered, only shown")
    }

    /// Anything but off counts as up: a failed VPN still holds its block, so turning it off lowers protection.
    func testVPNUp() {
        XCTAssertFalse(MacState(vpn: MacState.vpnOff).vpnUp)
        XCTAssertFalse(MacState().vpnUp, "no VPN set up")
        for state in [MacState.vpnOn, MacState.vpnConnecting, MacState.vpnFailed] {
            XCTAssertTrue(MacState(vpn: state).vpnUp, state)
        }
    }
}
