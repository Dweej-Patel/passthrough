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
        // The Mac's switch shows no label of its own: the step names where it is.
        XCTAssertEqual(steps[1].detail, "On the Mac, open Passthrough and turn on the switch at the top of Settings \u{25B8} Remote Shell.")
        XCTAssertEqual(steps[2].detail, "With sharing on, plug this iPhone into the Mac. Its shells then show up on the Mac and Shells tabs by themselves.")
        XCTAssertTrue(steps.allSatisfy { $0.action == nil })
    }

    func testPCSentences() {
        XCTAssertEqual(HostCopy.noAccess(pc), "Paired. Turn on Remote access on Office-PC, then plug this iPhone in once.")
        XCTAssertEqual(HostCopy.unreachable(pc, fromAnywhere: true, lastHeard: "14:02"),
                       "Can't reach Office-PC. It may be asleep, off, or offline. Last heard 14:02.")
        XCTAssertEqual(HostCopy.unreachable(pc, fromAnywhere: true), "Can't reach Office-PC. It may be asleep, off, or offline.")
        XCTAssertEqual(HostCopy.unreachable(pc, fromAnywhere: false, lastHeard: "14:02"),
                       "Can't reach Office-PC. Use the same Wi-Fi, or turn on Tailscale on both devices.")
        XCTAssertEqual(HostCopy.wentToSleep(pc, at: "14:02", sleepsAfter: "30 minutes"),
                       "Office-PC went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC.")
        XCTAssertEqual(HostCopy.turnedOff(pc, at: "14:02"), "Remote access was turned off on Office-PC at 14:02. Turn it on there.")
        XCTAssertEqual(HostCopy.noRelay(pc), "Can't reach Office-PC from here. The relay isn't answering; it works on the PC's own network or Tailscale.")
        XCTAssertEqual(HostCopy.revoked(pc), "Office-PC no longer lets this iPhone in. Plug it into the PC to get access again.")
        XCTAssertEqual(HostCopy.shell(.nobodySignedIn, pc), "Sign in to Office-PC to use its shell.")
        XCTAssertEqual(HostCopy.shell(.someoneElseSignedIn, pc), "Someone else is signed in to Office-PC. Its shell starts when you sign in.")
        XCTAssertEqual(HostCopy.shell(.appNotOpen, pc), "Passthrough isn't open on Office-PC. Open it there.")
        // Neither host has a per-phone Shell switch: the sentence names what gives the shell back.
        XCTAssertEqual(HostCopy.shell(.switchedOff, pc),
                       "Office-PC doesn't let this iPhone open shells. Plug this iPhone into the PC with Remote access on to get access again.")
        XCTAssertEqual(HostCopy.shell(.switchedOff, mac),
                       "MacBook Pro doesn't let this iPhone open shells. Plug this iPhone into the Mac with Remote shell on to get access again.")
        XCTAssertEqual(HostCopy.error(.notAllowed, pc), HostCopy.shell(.switchedOff, pc))
        XCTAssertNil(HostCopy.shell(.available, pc))
        XCTAssertEqual(HostCopy.screen(.notInThisVersion, pc), "Office-PC's screen isn't in this version of Passthrough yet. Its shell works.")
        XCTAssertEqual(HostCopy.screen(.switchedOff, pc),
                       "Screen is off for this iPhone. On Office-PC, open Passthrough's Settings \u{25B8} Remote access and turn on Screen for it.")
        XCTAssertEqual(HostCopy.screen(.remoteDesktopOff, pc),
                       "Remote Desktop is off on Office-PC. Turn it on in Passthrough's Settings \u{25B8} Remote access there.")
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
        // The PC's switch, by the sentence beside it, on the page it's on.
        XCTAssertEqual(off[1].detail,
                       "On the PC, open Passthrough and turn on Use this PC's shell from your phones in Settings \u{25B8} Remote access. Windows asks for an administrator once.")
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
        XCTAssertEqual(none[1].detail,
                       "On a Mac, open Passthrough and turn on the switch at the top of Settings \u{25B8} Remote Shell. On a PC, open Passthrough and turn on Use this PC's shell from your phones in Settings \u{25B8} Remote access.")
    }

    /// The hero says "Can't reach it" and when it was last heard itself: its advice repeats neither.
    func testUnreachableAdvice() {
        XCTAssertNil(HostCopy.unreachableAdvice(pc, fromAnywhere: true))
        XCTAssertEqual(HostCopy.unreachableAdvice(pc, fromAnywhere: false), "Use the same Wi-Fi, or turn on Tailscale on both devices.")
        XCTAssertEqual(HostCopy.unreachableAdvice(mac, fromAnywhere: true), "Check that Remote shell is on and the Mac is awake.")
        for w in [mac, pc] {
            for fromAnywhere in [true, false] {
                let advice = HostCopy.unreachableAdvice(w, fromAnywhere: fromAnywhere) ?? ""
                XCTAssertFalse(advice.contains("Can't reach") || advice.contains("Last heard") || advice.contains(HostCopy.mayBeAsleep))
                // The full sentence is the hero's two lines' worth: nothing else is lost.
                XCTAssertTrue(HostCopy.unreachable(w, fromAnywhere: fromAnywhere).contains(advice.isEmpty ? HostCopy.mayBeAsleep : advice))
            }
        }
    }

    /// The Share row names the switch as each computer's settings call it.
    func testShareSentences() {
        XCTAssertEqual(HostCopy.shareOff(mac),
                       "Turn on May share access with other computers for this iPhone in Passthrough's settings on MacBook Pro.")
        XCTAssertEqual(HostCopy.shareOff(pc), "Turn on Share for this iPhone in Passthrough's Settings \u{25B8} Remote access on Office-PC.")
        XCTAssertEqual(HostCopy.shareScreenOnly(mac),
                       "Its screen, with another of your Macs. To share its shell or share with a PC, turn on May share access with other computers for this iPhone in Passthrough's settings on MacBook Pro.")
        XCTAssertEqual(HostCopy.noActivity(pc), "Office-PC doesn't record activity yet.")
    }

    /// A computer given access that can't take it says why, when its `host` does; a Mac's sentence is the old one.
    func testCantTakeAccess() {
        XCTAssertEqual(HostCopy.cantTakeAccess(HostInfo(kind: "windows", signedIn: false, app: false), pc),
                       "Sign in to Office-PC and open Passthrough there, then try again.")
        XCTAssertEqual(HostCopy.cantTakeAccess(HostInfo(kind: "windows", signedIn: true, app: false), pc),
                       "Open Passthrough on Office-PC, then try again.")
        XCTAssertEqual(HostCopy.cantTakeAccess(HostInfo(kind: "windows", signedIn: true, app: true), pc),
                       "Office-PC needs the latest Passthrough to use other computers.")
        XCTAssertEqual(HostCopy.cantTakeAccess(HostInfo(kind: "mac"), mac),
                       "MacBook Pro needs the latest Passthrough to use other computers.")
        XCTAssertEqual(HostCopy.cantTakeAccess(nil, mac), "MacBook Pro needs the latest Passthrough to use other computers.")
    }

    /// A PC confirms keeping access on its own screen, so the phone says to look there; a Mac keeps it as before.
    func testHandingOver() {
        XCTAssertEqual(HostCopy.handingOver(pc), "Confirm on Office-PC when it asks (Windows Hello or the account's password)…")
        XCTAssertEqual(HostCopy.handingOver(mac), "Handing it to MacBook Pro…")
    }

    func testSwitcherKindPrefix() {
        let now = Date()
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 0), now: now, kind: .windows, showKind: true), "PC · Connected")
        XCTAssertEqual(MacProfiles.statusText(.noShell, now: now, kind: .windows, showKind: true), "PC · Paired, no access yet")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 1), now: now, kind: .mac, showKind: true), "Mac · Connected · 1 shell open")
        XCTAssertEqual(MacProfiles.statusText(.connected(shells: 1), now: now), "Connected · 1 shell open")
    }
}
