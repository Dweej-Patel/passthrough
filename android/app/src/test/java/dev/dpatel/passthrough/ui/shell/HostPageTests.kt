package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.HostAccess
import dev.dpatel.passthrough.core.HostFarewell
import dev.dpatel.passthrough.core.HostInfo
import dev.dpatel.passthrough.core.HostKind
import dev.dpatel.passthrough.core.HostShell
import dev.dpatel.passthrough.core.ShellError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** One test per row of the PC's page (stage 2 plan, section 4), and the precedences between them. */
class HostPageTests {
    private val pc = HostInfo(
        kind = "windows", signedIn = true, app = true, console = "active",
        shells = listOf(HostShell("pwsh", "PowerShell", default = true), HostShell("wsl:Ubuntu", "Ubuntu")),
        screens = listOf("rdp"), rdp = "ready", access = HostAccess(shell = true, screen = true), lock = true,
    )

    private fun page(
        reach: ShellReach = ShellReach.READY,
        host: HostInfo? = pc,
        kind: HostKind? = HostKind.WINDOWS,
        farewell: String? = null,
        accessRefused: Boolean = false,
        refusal: ShellError? = null,
        triedFromAnywhere: Boolean = false,
        relay: RelayHealth = RelayHealth.UNKNOWN,
        redialing: Boolean = false,
        since: Long? = null,
        now: Long = 100_000,
    ) = HostPage.make(HostPageInput(
        kind = kind, reach = reach, redialing = redialing, accessRefused = accessRefused, host = host,
        farewell = farewell?.let { HostFarewell(it, 1) }, connectingSinceMillis = since, triedFromAnywhere = triedFromAnywhere,
        relay = relay, shellRefusal = refusal, nowMillis = now,
    ))

    // State

    @Test fun connected() {
        val p = page()
        assertEquals(HostPageState.CONNECTED, p.state)
        assertEquals(HostShellState.AVAILABLE, p.shell)
        assertFalse(p.canRetry)
    }

    @Test fun connectingOffersTryAgainAfterThirtySeconds() {
        assertEquals(HostPageState.CONNECTING, page(ShellReach.CONNECTING, since = 90_000).state)
        assertFalse(page(ShellReach.CONNECTING, since = 90_000).canRetry)
        assertTrue(page(ShellReach.CONNECTING, since = 70_000).canRetry)
        assertEquals(HostPageState.RECONNECTING, page(ShellReach.CONNECTING, redialing = true).state)
    }

    @Test fun unreachableCauseUnknown() {
        val p = page(ShellReach.UNREACHABLE)
        assertEquals(HostPageState.UNREACHABLE, p.state)
        assertTrue(p.canRetry)
    }

    @Test fun saidItWentToSleep() = assertEquals(HostPageState.WENT_TO_SLEEP, page(ShellReach.UNREACHABLE, farewell = "sleeping").state)

    @Test fun saidRemoteAccessWasTurnedOff() = assertEquals(HostPageState.TURNED_OFF, page(ShellReach.UNREACHABLE, farewell = "turned_off").state)

    @Test fun saidItWasShuttingDown() = assertEquals(HostPageState.SHUT_DOWN, page(ShellReach.UNREACHABLE, farewell = "shutting_down").state)

    @Test fun anUnknownFarewellIsCauseUnknown() = assertEquals(HostPageState.UNREACHABLE, page(ShellReach.UNREACHABLE, farewell = "melting").state)

    @Test fun noRelay() {
        assertEquals(HostPageState.NO_RELAY, page(ShellReach.UNREACHABLE, triedFromAnywhere = true, relay = RelayHealth.SILENT).state)
        assertEquals("not tried from anywhere", HostPageState.UNREACHABLE, page(ShellReach.UNREACHABLE, relay = RelayHealth.SILENT).state)
        assertEquals("the relay answers", HostPageState.UNREACHABLE, page(ShellReach.UNREACHABLE, triedFromAnywhere = true, relay = RelayHealth.ANSWERING).state)
    }

    @Test fun aFarewellBeatsTheRelay() =
        assertEquals(HostPageState.WENT_TO_SLEEP, page(ShellReach.UNREACHABLE, farewell = "sleeping", triedFromAnywhere = true, relay = RelayHealth.SILENT).state)

    @Test fun accessRevoked() = assertEquals(HostPageState.REVOKED, page(ShellReach.NO_ACCESS, accessRefused = true).state)

    @Test fun pairedNoAccessYet() = assertEquals(HostPageState.PAIRED_NO_ACCESS, page(ShellReach.NO_ACCESS, host = null).state)

    @Test fun thePhonesOwnStates() {
        assertEquals(HostPageState.LOCKED, page(ShellReach.LOCKED).state)
        assertEquals(HostPageState.NEEDS_PASSCODE, page(ShellReach.NEEDS_PASSCODE).state)
        assertEquals(HostPageState.KEY_UNAVAILABLE, page(ShellReach.KEY_UNAVAILABLE).state)
        assertEquals(HostPageState.UNSUPPORTED, page(ShellReach.UNSUPPORTED).state)
    }

    @Test fun aMacNeverGetsAPCsReasons() {
        val mac = page(ShellReach.UNREACHABLE, kind = HostKind.MAC, host = null, farewell = "sleeping", triedFromAnywhere = true, relay = RelayHealth.SILENT)
        assertEquals(HostPageState.UNREACHABLE, mac.state)
        assertEquals(HostScreenState.AVAILABLE, mac.screen)
        assertEquals(HostShellState.AVAILABLE, mac.shell)
    }

    // Shell

    @Test fun shellNobodySignedIn() = assertEquals(HostShellState.NOBODY_SIGNED_IN, page(host = pc.copy(signedIn = false, app = false, console = "signedOut")).shell)

    @Test fun shellSomeoneElseSignedIn() = assertEquals(HostShellState.SOMEONE_ELSE_SIGNED_IN, page(host = pc.copy(signedIn = false, console = "otherUser")).shell)

    @Test fun shellPassthroughClosedThere() {
        assertEquals(HostShellState.APP_NOT_OPEN, page(host = pc.copy(app = false)).shell)
        assertEquals("signed_out with no host: the least specific true sentence", HostShellState.APP_NOT_OPEN, page(host = null, refusal = ShellError.SIGNED_OUT).shell)
    }

    @Test fun shellSwitchOff() {
        assertEquals(HostShellState.SWITCHED_OFF, page(host = pc.copy(access = HostAccess(shell = false, screen = true))).shell)
        assertEquals("an open refused not_allowed", HostShellState.SWITCHED_OFF, page(refusal = ShellError.NOT_ALLOWED).shell)
    }

    @Test fun aRefusalStandsOverAHostThatLooksFine() = assertEquals(HostShellState.APP_NOT_OPEN, page(refusal = ShellError.SIGNED_OUT).shell)

    // Screen

    @Test fun appTooOld() {
        assertEquals(HostScreenState.NOT_IN_THIS_VERSION, page().screen)
        assertEquals("no host yet", HostScreenState.NOT_IN_THIS_VERSION, page(host = null).screen)
    }

    @Test fun screenSwitchOff() = assertEquals(HostScreenState.SWITCHED_OFF, page(host = pc.copy(screens = emptyList(), rdp = null, access = HostAccess(shell = true, screen = false))).screen)

    @Test fun remoteDesktopOff() = assertEquals(HostScreenState.REMOTE_DESKTOP_OFF, page(host = pc.copy(screens = emptyList(), rdp = "off")).screen)

    @Test fun windowsHome() = assertEquals(HostScreenState.WINDOWS_HOME, page(host = pc.copy(screens = emptyList(), rdp = "edition")).screen)

    @Test fun accountHasNoPassword() = assertEquals(HostScreenState.NO_PASSWORD, page(host = pc.copy(screens = emptyList(), rdp = "account")).screen)

    @Test fun remoteDesktopNeedsALook() {
        for (rdp in listOf("service", "exposed", "policy")) {
            assertEquals(rdp, HostScreenState.REMOTE_DESKTOP_PROBLEM, page(host = pc.copy(screens = emptyList(), rdp = rdp)).screen)
        }
    }

    @Test fun nothingOfferedNoRow() = assertEquals(HostScreenState.NONE, page(host = pc.copy(screens = emptyList(), rdp = null)).screen)

    @Test fun aViewerThatCanShowRdpWouldShowIt() =
        assertEquals(HostScreenState.AVAILABLE, HostPage.make(HostPageInput(HostKind.WINDOWS, ShellReach.READY, host = pc, viewerScreens = setOf("rdp"))).screen)

    /** The gate: while this app shows no PC screens, no PC input ever reads as a screen it can open. */
    @Test fun noPcScreenIsAvailableInThisVersion() {
        val hosts = listOf(null, pc, pc.copy(screens = listOf("rdp", "video", "rfb")), pc.copy(screens = emptyList(), rdp = null))
        for (reach in ShellReach.entries) for (host in hosts) {
            assertNotEquals("$reach $host", HostScreenState.AVAILABLE, page(reach, host = host).screen)
        }
        assertTrue(ScreenBackends.supported(HostKind.WINDOWS).isEmpty())
    }

    @Test fun anUnknownKindShowsOnlyShells() {
        val p = page(kind = null, host = HostInfo(kind = "toaster"))
        assertEquals(HostScreenState.NONE, p.screen)
        assertEquals(HostShellState.AVAILABLE, p.shell)
    }
}
