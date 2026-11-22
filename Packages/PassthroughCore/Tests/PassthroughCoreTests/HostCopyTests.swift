import XCTest
@testable import PassthroughCore

final class HostCopyTests: XCTestCase {
    private let mac = HostWords(kind: .mac, name: "MacBook Pro", device: "iPhone")
    private let pc = HostWords(kind: .windows, name: "Office-PC", device: "iPhone")

    func testWords() {
        XCTAssertEqual(mac.your, "your Mac")
        XCTAssertEqual(pc.Your, "Your PC")
        XCTAssertEqual(pc.the, "the PC")
        XCTAssertEqual(HostWords.generic(device: "iPhone").plural, "computers")
        XCTAssertEqual(HostWords(kind: .other, name: nil, device: "iPad").name, "Your computer")
        XCTAssertEqual(HostWords(kind: .windows, name: "", device: "iPhone").name, "Your PC")
        XCTAssertEqual(pc.symbol, "pc")
        XCTAssertEqual(mac.symbol, "laptopcomputer")
        XCTAssertEqual(HostWords.generic(device: "iPhone").Noun, "Computer")
    }

    /// The Mac variant of each sentence is the one the app showed before PCs, word for word.
    func testMacSentencesUnchanged() {
        XCTAssertEqual(HostCopy.keyUnavailable(mac), "Couldn't read the Remote shell key. Plug into the Mac again to renew access.")
        XCTAssertEqual(HostCopy.noAccess(mac), "Turn on Remote shell in Passthrough on your Mac, then connect this iPhone with the cable once.")
        XCTAssertEqual(HostCopy.revoked(mac), HostCopy.noAccess(mac))
        XCTAssertEqual(HostCopy.unreachable(mac, fromAnywhere: true, lastHeard: "14:02"),
                       "Can't reach your Mac. Check that Remote shell is on and the Mac is awake.")
        XCTAssertEqual(HostCopy.unreachable(mac, fromAnywhere: false), "Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices.")
        XCTAssertEqual(HostCopy.cantReach(mac), "Can't reach Mac")
        XCTAssertEqual(HostCopy.pairedNoShell(.mac), "Paired, no Remote shell")
        XCTAssertEqual(HostCopy.reachBlockNoAccess(mac), "To change these from this iPhone, set up Remote shell on the Mac. The steps are below.")
        XCTAssertEqual(HostCopy.screen(.available, mac), "See and control the Mac's screen")
        XCTAssertEqual(HostCopy.error(.tooManySessions, mac), "Your Mac already has \(RemoteShell.maxSessions) sessions open. End one to start another.")
        XCTAssertEqual(HostCopy.error(.noSuchSession, mac), "That session is no longer open on your Mac.")
        XCTAssertEqual(HostCopy.error(.badRequest, mac), "Your Mac couldn't do that. Try again.")
        XCTAssertEqual(HostCopy.error(.screenNotAllowed, mac),
                       "This iPhone isn't allowed to see your Mac's screen. Turn on Screen for it in Passthrough's Remote Shell settings on your Mac.")
        XCTAssertEqual(HostCopy.error(.notAllowed, mac),
                       "Your Mac doesn't let this iPhone change Keep awake and the VPN. Turn on Awake & VPN for it in Passthrough's Remote Shell settings on your Mac.")
        XCTAssertEqual(HostCopy.error(.screenOnly, mac), "That Mac only lets this device see its screen.")
        XCTAssertEqual(HostCopy.error(.tooManyScreens, mac),
                       "Your Mac is already showing its screen as often as it allows (\(RemoteShell.maxScreenViewsPerPhone) views per phone, \(RemoteShell.maxScreenViews) in all). Close one to open another.")
        XCTAssertNil(HostCopy.error(.notAuthorized, mac))
        let steps = HostCopy.setupSteps(mac, paired: true, isPad: false, cableLinkOn: true, needsVPNPrompt: false)
        XCTAssertEqual(steps.map(\.title), ["Pair this iPhone with your Mac", "Turn on Remote shell on your Mac", "Connect over USB once"])
        XCTAssertEqual(steps[0].detail, "Done.")
        XCTAssertEqual(steps[2].detail, "With sharing on, plug this iPhone into the Mac. Its shells then show up on the Mac and Shells tabs by themselves.")
        XCTAssertTrue(steps.allSatisfy { $0.action == nil })
    }

    func testPCSentences() {
        XCTAssertEqual(HostCopy.noAccess(pc), "Paired. Turn on Remote access on Office-PC, then plug this iPhone in once.")
        XCTAssertEqual(HostCopy.unreachable(pc, fromAnywhere: true, lastHeard: "14:02"),
                       "Can't reach Office-PC. It may be asleep, off, or offline. Last heard 14:02.")
        XCTAssertEqual(HostCopy.unreachable(pc, fromAnywhere: true), "Can't reach Office-PC. It may be asleep, off, or offline.")
        XCTAssertEqual(HostCopy.wentToSleep(pc, at: "14:02", sleepsAfter: "30 minutes"),
                       "Office-PC went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC.")
        XCTAssertEqual(HostCopy.turnedOff(pc, at: "14:02"), "Remote access was turned off on Office-PC at 14:02. Turn it on there.")
        XCTAssertEqual(HostCopy.noRelay(pc), "Can't reach Office-PC from here. The relay isn't answering; it works on the PC's own network or Tailscale.")
        XCTAssertEqual(HostCopy.revoked(pc), "Office-PC no longer lets this iPhone in. Plug it into the PC to get access again.")
        XCTAssertEqual(HostCopy.shell(.nobodySignedIn, pc), "Sign in to Office-PC to use its shell.")
        XCTAssertEqual(HostCopy.shell(.someoneElseSignedIn, pc), "Someone else is signed in to Office-PC. Its shell starts when you sign in.")
        XCTAssertEqual(HostCopy.shell(.appNotOpen, pc), "Passthrough isn't open on Office-PC. Open it there.")
        XCTAssertEqual(HostCopy.shell(.switchedOff, pc),
                       "Office-PC doesn't let this iPhone open shells. Turn on Shell for it in Passthrough's settings on the PC.")
        XCTAssertNil(HostCopy.shell(.available, pc))
        XCTAssertEqual(HostCopy.screen(.notInThisVersion, pc), "Office-PC's screen isn't in this version of Passthrough yet. Its shell works.")
        XCTAssertEqual(HostCopy.screen(.windowsHome, pc), "Office-PC runs Windows Home, which has no Remote Desktop. The shell works.")
        XCTAssertNil(HostCopy.screen(.noRow, pc))
        XCTAssertEqual(HostCopy.error(.signedOut, pc), HostCopy.shell(.appNotOpen, pc))
        XCTAssertEqual(HostCopy.error(.tooManySessions, pc), "Your PC already has \(RemoteShell.maxSessions) sessions open. End one to start another.")
        XCTAssertEqual(HostCopy.pairedNoShell(.windows), "Paired, no access yet")
        XCTAssertEqual(HostCopy.title(.wentToSleep(at: .now)), "Asleep")
    }

    func testPCSetupSteps() {
        let off = HostCopy.setupSteps(pc, paired: true, isPad: false, cableLinkOn: false, needsVPNPrompt: true)
        XCTAssertEqual(off.map(\.title), ["Pair this iPhone with your PC", "Turn on Remote access on your PC", "Plug this iPhone in once"])
        XCTAssertEqual(off[2].action, .turnOnCableLink)
        XCTAssertEqual(off[2].note, "iOS asks to add a VPN configuration. That is how the cable link works; no traffic is sent through it for a PC.")
        XCTAssertNil(HostCopy.setupSteps(pc, paired: true, isPad: false, cableLinkOn: false, needsVPNPrompt: false)[2].note)
        let on = HostCopy.setupSteps(pc, paired: true, isPad: false, cableLinkOn: true, needsVPNPrompt: true)
        XCTAssertNil(on[2].action)
        XCTAssertEqual(on[2].detail, "Plug this iPhone into the PC with Passthrough open here. The PC then appears with its shells.")
        let pad = HostCopy.setupSteps(HostWords(kind: .windows, name: "Office-PC", device: "iPad"), paired: true, isPad: true,
                                      cableLinkOn: false, needsVPNPrompt: true)
        XCTAssertEqual(pad[2].detail, "With Passthrough open, plug this iPad into the PC.")
        XCTAssertNil(pad[2].action)
        let none = HostCopy.setupSteps(.generic(device: "iPhone"), paired: false, isPad: false, cableLinkOn: false, needsVPNPrompt: false)
        XCTAssertEqual(none[0].title, "Pair this iPhone with your Mac or PC")
        XCTAssertFalse(none[0].done)
    }

    func testSwitcherKindPrefix() {
        let now = Date()
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 0), now: now, kind: .windows, showKind: true), "PC · Connected")
        XCTAssertEqual(MacProfiles.statusText(.noShell, now: now, kind: .windows, showKind: true), "PC · Paired, no access yet")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 1), now: now, kind: .mac, showKind: true), "Mac · Connected · 1 shell open")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 1), now: now), "Connected · 1 shell open")
    }
}
