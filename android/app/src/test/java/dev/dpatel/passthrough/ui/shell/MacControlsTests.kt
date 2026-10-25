package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.ShellError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacControlsTests {
    private val awakeOn = MacControl.Awake(true)
    private val vpnOff = MacControl.Vpn(false)

    /** Two changes in flight: the first landing leaves the second's spinner. */
    @Test fun eachSwitchClearsOnItsOwn() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.request(vpnOff, ready = true, now = 0)
        c.stateArrived(MacState(awake = true, vpn = MacStates.VPN_ON))
        assertEquals(listOf<MacControl>(vpnOff), c.pending)
        c.stateArrived(MacState(awake = true, vpn = MacStates.VPN_OFF))
        assertTrue(c.pending.isEmpty())
    }

    @Test fun aNewChangeReplacesTheSameSwitch() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.request(MacControl.Awake(false), ready = true, now = 0)
        assertEquals(listOf<MacControl>(MacControl.Awake(false)), c.pending)
    }

    /** Refused at the battery limit: the Mac says why, so the spinner stops. */
    @Test fun awakeRefusedAtTheLimitIsAnswered() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.stateArrived(MacState(awake = false, awakeStopped = MacStates.STOPPED_BATTERY))
        assertTrue(c.pending.isEmpty())
    }

    @Test fun disconnectingDropsWhatWasSent() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.disconnected()
        assertTrue(c.pending.isEmpty())
    }

    @Test fun noAnswerStopsWaiting() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.expire(MacControls.ANSWER_MS - 1)
        assertEquals(listOf<MacControl>(awakeOn), c.pending)
        c.expire(MacControls.ANSWER_MS)
        assertTrue(c.pending.isEmpty())
        assertNull(c.error)
    }

    /** A VPN-off confirmed behind a PIN screen that stopped the app: held through the drop, sent once ready. */
    @Test fun aChangeMadeWhileUnreachableIsHeldAndSent() {
        val c = MacControls()
        c.request(vpnOff, ready = false, now = 0)
        c.disconnected()
        assertEquals(listOf<MacControl>(vpnOff), c.pending)
        assertEquals(listOf<MacControl>(vpnOff), c.readied(now = 5_000))
        assertTrue(c.readied(now = 5_000).isEmpty())
        // Now it waits for its answer, timed from when it went out.
        c.expire(5_000 + MacControls.ANSWER_MS - 1)
        assertEquals(listOf<MacControl>(vpnOff), c.pending)
        c.stateArrived(MacState(vpn = MacStates.VPN_OFF))
        assertTrue(c.pending.isEmpty())
    }

    @Test fun aHeldChangeGivesUpVisibly() {
        val c = MacControls()
        c.request(vpnOff, ready = false, now = 0)
        c.expire(MacControls.HOLD_MS - 1)
        assertEquals(listOf<MacControl>(vpnOff), c.pending)
        c.expire(MacControls.HOLD_MS)
        assertTrue(c.pending.isEmpty())
        assertEquals(MacControlError.NOT_SENT, c.error)
    }

    @Test fun refusalClearsAndSays() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.refused(ShellError.NOT_ALLOWED)
        assertTrue(c.pending.isEmpty())
        assertEquals(MacControlError.NOT_ALLOWED, c.error)
    }

    /** VPN not set up ends only the VPN change. */
    @Test fun vpnRefusalLeavesKeepAwake() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.request(MacControl.Vpn(true), ready = true, now = 0)
        c.refused(ShellError.VPN_NOT_SET_UP)
        assertEquals(listOf<MacControl>(awakeOn), c.pending)
        assertEquals(MacControlError.VPN_NOT_SET_UP, c.error)
    }

    /** The owner allowed this phone since: the refusal goes once the Mac says so. */
    @Test fun allowedAgainClearsTheRefusal() {
        val c = MacControls()
        c.refused(ShellError.NOT_ALLOWED)
        c.stateArrived(MacState(control = false))
        assertEquals(MacControlError.NOT_ALLOWED, c.error)
        c.stateArrived(MacState(control = true))
        assertNull(c.error)
    }

    @Test fun aVpnSetUpClearsItsRefusal() {
        val c = MacControls()
        c.refused(ShellError.VPN_NOT_SET_UP)
        c.stateArrived(MacState(control = true))
        assertEquals(MacControlError.VPN_NOT_SET_UP, c.error)
        c.stateArrived(MacState(control = true, vpn = MacStates.VPN_OFF))
        assertNull(c.error)
    }

    @Test fun otherErrorsAreNotControlRefusals() {
        val c = MacControls()
        c.request(awakeOn, ready = true, now = 0)
        c.refused(ShellError.NO_SUCH_SESSION)
        assertEquals(listOf<MacControl>(awakeOn), c.pending)
        assertNull(c.error)
    }
}
