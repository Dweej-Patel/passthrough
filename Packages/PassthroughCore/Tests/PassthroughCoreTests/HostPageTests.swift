import XCTest
@testable import PassthroughCore

/// One test per row of the PC's page (stage 2 plan, section 4), and the kind rules under it.
final class HostPageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pc(_ reach: HostReach, host: HostInfo? = nil, farewell: HostFarewell? = nil, accessRefused: Bool = false,
                    connectingSince: Date? = nil, triedFromAnywhere: Bool = false, relay: RelayHealth = .unknown,
                    refusal: ShellError? = nil) -> HostPage {
        HostPage.make(HostPageInput(kind: .windows, reach: reach, accessRefused: accessRefused, host: host, farewell: farewell,
                                    connectingSince: connectingSince, triedFromAnywhere: triedFromAnywhere, relay: relay,
                                    shellRefusal: refusal, now: now))
    }

    private func host(signedIn: Bool? = true, app: Bool? = true, console: String? = nil, screens: [String]? = ["rdp"],
                      rdp: String? = "ready", access: HostAccess? = nil) -> HostInfo {
        HostInfo(kind: "windows", signedIn: signedIn, app: app, console: console, shells: [HostShell(id: "pwsh", name: "PowerShell", default: true)],
                 screens: screens, rdp: rdp, access: access)
    }

    // MARK: State

    func testConnected() {
        let page = pc(.ready(.relay), host: host())
        XCTAssertEqual(page.state, .connected(.relay))
        XCTAssertEqual(page.shell, .available)
        XCTAssertFalse(page.canRetry)
    }

    func testConnectingOffersTryAgainAfterThirtySeconds() {
        XCTAssertEqual(pc(.connecting(redialing: false)).state, .connecting)
        XCTAssertEqual(pc(.connecting(redialing: true)).state, .reconnecting)
        XCTAssertFalse(pc(.connecting(redialing: false), connectingSince: now.addingTimeInterval(-29)).canRetry)
        XCTAssertTrue(pc(.connecting(redialing: false), connectingSince: now.addingTimeInterval(-30)).canRetry)
        XCTAssertFalse(pc(.connecting(redialing: false)).canRetry, "no start time: not yet")
    }

    func testUnreachableCauseUnknown() {
        let page = pc(.unreachable)
        XCTAssertEqual(page.state, .unreachable)
        XCTAssertTrue(page.canRetry)
    }

    func testWentToSleep() {
        let at = now.addingTimeInterval(-600)
        XCTAssertEqual(pc(.unreachable, farewell: HostFarewell(reason: "sleeping", at: at)).state, .wentToSleep(at: at))
    }

    func testTurnedOff() {
        XCTAssertEqual(pc(.unreachable, farewell: HostFarewell(reason: "turned_off", at: now)).state, .turnedOff(at: now))
    }

    func testShutDown() {
        XCTAssertEqual(pc(.unreachable, farewell: HostFarewell(reason: "shutting_down", at: now)).state, .shutDown(at: now))
    }

    func testUnknownFarewellIsCauseUnknown() {
        XCTAssertEqual(pc(.unreachable, farewell: HostFarewell(reason: "updating", at: now)).state, .unreachable)
    }

    func testNoRelay() {
        XCTAssertEqual(pc(.unreachable, triedFromAnywhere: true, relay: .silent).state, .noRelay)
        XCTAssertEqual(pc(.unreachable, triedFromAnywhere: true, relay: .answering).state, .unreachable)
        XCTAssertEqual(pc(.unreachable, triedFromAnywhere: false, relay: .silent).state, .unreachable)
    }

    func testFarewellBeatsRelay() {
        XCTAssertEqual(pc(.unreachable, farewell: HostFarewell(reason: "sleeping", at: now), triedFromAnywhere: true, relay: .silent).state,
                       .wentToSleep(at: now))
    }

    func testRevokedAndPairedNoAccess() {
        XCTAssertEqual(pc(.noAccess, accessRefused: true).state, .revoked)
        XCTAssertEqual(pc(.noAccess).state, .pairedNoAccess)
    }

    func testPhoneSideStates() {
        XCTAssertEqual(pc(.locked).state, .locked)
        XCTAssertEqual(pc(.needsPasscode).state, .needsPasscode)
        XCTAssertEqual(pc(.keyUnavailable).state, .keyUnavailable)
    }

    // MARK: Shell

    func testShellNobodySignedIn() {
        XCTAssertEqual(pc(.ready(.local), host: host(signedIn: false, app: false, console: "signedOut")).shell, .nobodySignedIn)
        XCTAssertEqual(pc(.ready(.local), host: host(signedIn: false, app: false)).shell, .nobodySignedIn)
    }

    func testShellSomeoneElseSignedIn() {
        XCTAssertEqual(pc(.ready(.local), host: host(signedIn: false, app: false, console: "otherUser")).shell, .someoneElseSignedIn)
    }

    func testShellAppNotOpen() {
        XCTAssertEqual(pc(.ready(.local), host: host(signedIn: true, app: false, console: "locked")).shell, .appNotOpen)
        XCTAssertEqual(pc(.ready(.local), refusal: .signedOut).shell, .appNotOpen, "signed_out with no host: the least specific true sentence")
    }

    func testShellSwitchedOff() {
        XCTAssertEqual(pc(.ready(.local), host: host(access: HostAccess(shell: false, screen: true))).shell, .switchedOff)
        XCTAssertEqual(pc(.ready(.local), refusal: .notAllowed).shell, .switchedOff)
    }

    func testRefusalBeatsHostFactsUntilANewerHost() {
        // The refusal is kept with stale facts; a newer `host` clearing it is the model's job, so here both are in.
        XCTAssertEqual(pc(.ready(.local), host: host(), refusal: .signedOut).shell, .appNotOpen)
        XCTAssertEqual(pc(.ready(.local), host: host()).shell, .available)
    }

    // MARK: Screen

    func testScreenNotInThisVersionWhenOffered() {
        XCTAssertEqual(pc(.ready(.local), host: host(screens: ["rdp"], rdp: "ready")).screen, .notInThisVersion)
        XCTAssertEqual(pc(.ready(.local)).screen, .notInThisVersion, "no host yet: still not in this version")
    }

    func testScreenReasonsWhenNothingOffered() {
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: "edition")).screen, .windowsHome)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: "off")).screen, .remoteDesktopOff)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: "account")).screen, .noPassword)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: "service")).screen, .remoteDesktopProblem)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: "exposed")).screen, .remoteDesktopProblem)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: [], rdp: nil, access: HostAccess(screen: false))).screen, .switchedOff)
        XCTAssertEqual(pc(.ready(.local), host: host(screens: nil, rdp: nil)).screen, HostScreenState.none)
    }

    func testScreenAvailableOnceThisAppHasTheViewer() {
        let input = HostPageInput(kind: .windows, reach: .ready(.local), host: host(screens: ["rdp"]), viewerScreens: ["rdp"], now: now)
        XCTAssertEqual(HostPage.make(input).screen, .available)
    }

    /// The gate: while this app has no viewer for a PC, no PC input ever reaches the screen.
    func testNoWindowsInputReachesTheScreen() {
        XCTAssertTrue(ScreenBackends.supported(for: .windows).isEmpty)
        let hosts: [HostInfo?] = [nil, host(), host(screens: ["rdp", "video", "rfb"]), host(screens: [], rdp: "edition"),
                                  HostInfo(kind: "windows", screens: ["video"])]
        let reaches: [HostReach] = [.noAccess, .locked, .connecting(redialing: false), .unreachable, .ready(nil), .ready(.relay)]
        for h in hosts { for r in reaches {
            XCTAssertNotEqual(pc(r, host: h).screen, .available, "\(String(describing: h)) \(r)")
        } }
    }

    func testMacScreenIsAsBefore() {
        XCTAssertEqual(HostPage.make(HostPageInput(kind: .mac, reach: .ready(.local), now: now)).screen, .available)
        XCTAssertEqual(HostPage.make(HostPageInput(kind: .other, reach: .ready(.local), now: now)).screen, HostScreenState.none)
    }

    // MARK: Kind

    func testKindPrecedence() {
        XCTAssertEqual(Hosts.kind(live: nil, stored: nil), .mac, "a computer that never said is a Mac")
        XCTAssertEqual(Hosts.kind(live: nil, stored: "windows"), .windows)
        XCTAssertEqual(Hosts.kind(live: nil, stored: "toaster"), .mac)
        XCTAssertEqual(Hosts.kind(live: HostInfo(kind: "mac"), stored: "windows"), .mac, "live beats stored")
        XCTAssertEqual(Hosts.kind(live: HostInfo(kind: "windows"), stored: nil), .windows)
        XCTAssertEqual(Hosts.kind(live: HostInfo(kind: "toaster"), stored: "windows"), .other)
    }

    func testDefaultShell() {
        let info = HostInfo(kind: "windows", shells: [HostShell(id: "cmd", name: "Command Prompt"), HostShell(id: "pwsh", name: "PowerShell", default: true)])
        XCTAssertEqual(info.defaultShell?.id, "pwsh")
        XCTAssertEqual(HostInfo(kind: "windows", shells: [HostShell(id: "cmd", name: "Command Prompt")]).defaultShell?.id, "cmd")
        XCTAssertNil(HostInfo(kind: "mac").defaultShell)
    }
}
