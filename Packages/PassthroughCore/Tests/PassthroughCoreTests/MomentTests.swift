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

    /// Picking a moment changes only what differs, and says when it lowers protection or lets the Mac sleep.
    func testPlanChangesOnlyWhatDiffers() {
        XCTAssertEqual(Moment.desk.plan(internet: true, awake: false, vpn: false), MomentPlan())
        XCTAssertTrue(Moment.desk.plan(internet: true, awake: false, vpn: false)!.isEmpty)

        let fromPublic = Moment.desk.plan(internet: true, awake: false, vpn: true)!
        XCTAssertEqual(fromPublic, MomentPlan(vpn: false))
        XCTAssertTrue(fromPublic.lowersVPN)
        XCTAssertFalse(fromPublic.letsSleep)

        let fromAway = Moment.public.plan(internet: false, awake: true, vpn: false)!
        XCTAssertEqual(fromAway, MomentPlan(internet: true, awake: false, vpn: true))
        XCTAssertTrue(fromAway.letsSleep)
        XCTAssertTrue(fromAway.needsVPN)
        XCTAssertFalse(fromAway.lowersVPN)

        XCTAssertEqual(Moment.away.plan(internet: true, awake: false, vpn: true), MomentPlan(internet: false, awake: true),
                       "Away leaves the VPN alone")
        XCTAssertNil(Moment.custom.plan(internet: true, awake: true, vpn: true))
    }

    /// A Mac that says where it's online is read the same by every phone; an older one falls back to this phone sharing.
    func testMomentFromMacState() {
        let away = MacState(awake: true, vpn: MacState.vpnOff, internet: false)
        XCTAssertEqual(away.moment(phoneSharing: true), .away, "the phone still sharing doesn't make it Desk")
        XCTAssertEqual(MacState(awake: false, vpn: MacState.vpnOff).moment(phoneSharing: true), .desk)
        XCTAssertEqual(MacState(awake: false, vpn: MacState.vpnOn, internet: true).moment(phoneSharing: false), .public)
    }

    func testCaptionNamesThePhoneAndTheReach() {
        XCTAssertTrue(Moment.desk.caption(phone: "this iPhone").contains("this iPhone"))
        XCTAssertTrue(Moment.away.caption(phone: "the phone").contains("from anywhere"))
        XCTAssertTrue(Moment.away.caption(phone: "the phone", fromAnywhere: false).contains("on its network"))
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
