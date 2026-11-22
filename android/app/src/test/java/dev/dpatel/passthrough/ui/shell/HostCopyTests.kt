package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.HostKind
import dev.dpatel.passthrough.core.HostWords
import dev.dpatel.passthrough.core.ShellError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Phones know a PC: every Mac sentence that moved into [HostCopy] reads exactly as before (the
 * literals below are the app's before PCs), and the PC's read as the plan writes them.
 */
class HostCopyTests {
    private val mac = HostWords(HostKind.MAC, "MacBook Pro")
    private val pc = HostWords(HostKind.WINDOWS, "Office-PC")

    @Test fun macSentencesAreUnchanged() {
        assertEquals("Turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once.", HostCopy.noAccess(mac))
        assertEquals("Turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once.", HostCopy.revoked(mac))
        assertEquals("Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices.", HostCopy.unreachable(mac, fromAnywhere = false))
        assertEquals("Can't reach your Mac. Check that Remote shell is on and the Mac is awake.", HostCopy.unreachable(mac, fromAnywhere = true, lastHeard = "14:02"))
        assertEquals("Check that Remote shell is on and the Mac is awake.", HostCopy.unreachableDetail(mac, fromAnywhere = true))
        assertEquals("Couldn't read the Remote shell key. Plug into the Mac again to renew access.", HostCopy.keyUnavailable(mac))
        assertEquals("Your Mac already has 8 sessions open. End one to start another.", HostCopy.tooManySessions(mac))
        assertEquals("Connecting to MacBook Pro…", HostCopy.connecting(mac, "MacBook Pro", redialing = false))
        assertEquals("Reconnecting to your Mac…", HostCopy.connecting(mac, null, redialing = true))
        assertEquals("No sessions open on this Mac. Tap New to start one.", HostCopy.noSessions(mac))
        assertEquals("Open your Mac's shell from this phone. To set it up:", HostCopy.setupIntro(mac))
        assertEquals("Can't reach this Mac", HostCopy.cantReachTitle(mac, named = true))
        assertEquals("Can't reach your Mac", HostCopy.cantReachTitle(mac, named = false))
        assertEquals("This phone's Remote shell key can't be read. Start the proxy and plug into the Mac again to renew access.", HostCopy.renewKey(mac))
        assertEquals("Locked — everything keeps running", HostCopy.lockStatus(locked = true, asked = false, mac))
        assertEquals(listOf(
            "On your Mac, open Passthrough from the menu bar and turn on Remote shell.",
            "Start the proxy here and plug this phone into the Mac (pair it first if needed). The Mac sends this phone a key.",
            "That's it: your Mac's sessions show up here, over Wi-Fi, Tailscale or from anywhere.",
        ), HostCopy.setupSteps(mac, paired = true))
        assertNull("a Mac keeps its timeline", HostCopy.noTimeline(mac))
    }

    @Test fun shellReachKeepsTheMacWording() {
        assertEquals(HostCopy.noAccess(mac), ShellReach.NO_ACCESS.message)
        assertEquals(HostCopy.unreachable(mac, true), ShellReach.UNREACHABLE.message(fromAnywhere = true))
        assertEquals("Your Mac already has 8 sessions open. End one to start another.", ShellError.TOO_MANY_SESSIONS.message())
        assertEquals("Office-PC", pc.name)
        assertEquals("Paired. Turn on Remote access on Office-PC, then plug this phone in once.", ShellReach.NO_ACCESS.message(pc, fromAnywhere = false))
    }

    @Test fun pcReaching() {
        assertEquals("Paired. Turn on Remote access on Office-PC, then plug this phone in once.", HostCopy.noAccess(pc))
        assertEquals("Office-PC no longer lets this phone in. Plug it into the PC to get access again.", HostCopy.revoked(pc))
        assertEquals("Can't reach Office-PC. It may be asleep, off, or offline. Last heard 14:02.", HostCopy.unreachable(pc, fromAnywhere = true, lastHeard = "14:02"))
        assertEquals("Can't reach Office-PC. It may be asleep, off, or offline.", HostCopy.unreachable(pc, fromAnywhere = true))
        assertEquals("Can't reach Office-PC. Use the same Wi-Fi, or turn on Tailscale on both devices.", HostCopy.unreachable(pc, fromAnywhere = false))
        assertEquals("Office-PC went to sleep at 14:02. It sleeps after 30 minutes; turn on Stay awake in Passthrough on the PC.",
            HostCopy.wentToSleep(pc, "14:02", "30 minutes"))
        assertEquals("Office-PC went to sleep at 14:02. Turn on Stay awake in Passthrough on the PC to keep it reachable.", HostCopy.wentToSleep(pc, "14:02", null))
        assertEquals("Remote access was turned off on Office-PC at 14:02. Turn it on there.", HostCopy.turnedOff(pc, "14:02"))
        assertEquals("Office-PC was shut down or restarted at 14:02. It is reachable again once Windows has started.", HostCopy.shutDown(pc, "14:02"))
        assertEquals("Can't reach Office-PC from here. The relay isn't answering; it works on the PC's own network or Tailscale.", HostCopy.noRelay(pc))
        assertEquals("To use Office-PC from this phone, turn on Remote access there. The steps are below.", HostCopy.reachBlockNoAccess(pc))
    }

    @Test fun pcShellsAndScreen() {
        assertNull(HostCopy.shell(HostShellState.AVAILABLE, pc))
        assertEquals("Sign in to Office-PC to use its shell.", HostCopy.shell(HostShellState.NOBODY_SIGNED_IN, pc))
        assertEquals("Someone else is signed in to Office-PC. Its shell starts when you sign in.", HostCopy.shell(HostShellState.SOMEONE_ELSE_SIGNED_IN, pc))
        assertEquals("Passthrough isn't open on Office-PC. Open it there.", HostCopy.shell(HostShellState.APP_NOT_OPEN, pc))
        assertEquals("Office-PC doesn't let this phone open shells. Turn on Shell for it in Passthrough's settings on the PC.",
            HostCopy.shell(HostShellState.SWITCHED_OFF, pc))
        assertEquals("Office-PC's screen isn't in this version of Passthrough yet. Its shell works.", HostCopy.screen(HostScreenState.NOT_IN_THIS_VERSION, pc))
        assertEquals("Screen is off for this phone. On Office-PC, open Passthrough's settings and turn on Screen for it.", HostCopy.screen(HostScreenState.SWITCHED_OFF, pc))
        assertEquals("Remote Desktop is off on Office-PC. Turn it on in Passthrough's settings there.", HostCopy.screen(HostScreenState.REMOTE_DESKTOP_OFF, pc))
        assertEquals("Office-PC runs Windows Home, which has no Remote Desktop. The shell works.", HostCopy.screen(HostScreenState.WINDOWS_HOME, pc))
        assertEquals("Your account on Office-PC has no password Remote Desktop can use. Add one on the PC.", HostCopy.screen(HostScreenState.NO_PASSWORD, pc))
        assertEquals("Remote Desktop on Office-PC needs a look. Open Passthrough's settings on the PC.", HostCopy.screen(HostScreenState.REMOTE_DESKTOP_PROBLEM, pc))
        assertNull(HostCopy.screen(HostScreenState.NONE, pc))
        assertEquals("Locked — its shells keep running", HostCopy.lockStatus(locked = true, asked = false, pc))
        assertEquals("A PC keeps no timeline yet.", HostCopy.noTimeline(pc))
        assertEquals("Your PC already has 8 sessions open. End one to start another.", HostCopy.tooManySessions(pc))
    }

    @Test fun setupSteps() {
        assertEquals(listOf(
            "Pair this phone with your PC. Done.",
            "Turn on Remote access on your PC: open Passthrough's Settings there, go to Remote access and choose Turn on. Windows asks for an administrator once.",
            "Start sharing with the power button on This phone, then plug this phone into the PC.",
        ), HostCopy.setupSteps(pc, paired = true))
        assertEquals("Pair this phone with your Mac or PC.", HostCopy.setupSteps(HostWords.generic(), paired = false).first())
    }

    @Test fun titles() {
        assertEquals("Reachable", HostCopy.title(HostPageState.CONNECTED))
        assertEquals("Asleep", HostCopy.title(HostPageState.WENT_TO_SLEEP))
        assertEquals("Remote access is off", HostCopy.title(HostPageState.TURNED_OFF))
        assertEquals("No access", HostCopy.title(HostPageState.REVOKED))
        assertEquals("Paired", HostCopy.title(HostPageState.PAIRED_NO_ACCESS))
        assertEquals("Can't reach it from here", HostCopy.title(HostPageState.NO_RELAY))
    }
}
