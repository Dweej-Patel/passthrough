package dev.dpatel.passthrough.ui.mac

import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.service.ServiceState
import dev.dpatel.passthrough.ui.shell.MacControlError
import dev.dpatel.passthrough.ui.shell.ShellReach
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacSwitchesTests {
    private val ready = MacLink(paired = true, reach = ShellReach.READY, macName = "Studio")
    private val allowed = MacState(awake = false, vpn = MacStates.VPN_OFF, control = true)

    @Test fun internetSaysWhereTheMacIs() {
        assertEquals("Mac online through this phone", MacSwitches.internet(ServiceState.Running, 1, paired = true, usbDebugging = true).status)
        val waiting = MacSwitches.internet(ServiceState.Running, 0, paired = true, usbDebugging = true)
        assertEquals("Sharing — waiting for the Mac", waiting.status)
        assertNotNull(waiting.note)
        val off = MacSwitches.internet(ServiceState.Stopped, 0, paired = true, usbDebugging = true)
        assertFalse(off.on)
        assertTrue(off.enabled)
        assertEquals("Off", off.status)
    }

    @Test fun internetProblemsComeWithAFix() {
        assertEquals(SwitchFix.USB_DEBUGGING, MacSwitches.internet(ServiceState.Running, 0, paired = true, usbDebugging = false).note?.fix)
        assertEquals(SwitchFix.PAIR, MacSwitches.internet(ServiceState.Running, 0, paired = false, usbDebugging = true).note?.fix)
        val failed = MacSwitches.internet(ServiceState.Failed("Port in use"), 0, paired = true, usbDebugging = true)
        assertFalse(failed.on)
        assertEquals(SwitchFix.RETRY, failed.note?.fix)
        assertFalse(MacSwitches.internet(ServiceState.Starting, 0, paired = true, usbDebugging = true).enabled)
    }

    /** Every reason the Mac's switches can't change from here is said, once for both. */
    @Test fun macBlockNamesEachReason() {
        assertNull(MacSwitches.macBlock(ready, allowed, null))
        assertEquals(SwitchFix.PAIR, MacSwitches.macBlock(ready.copy(paired = false), null, null)?.fix)
        assertEquals(SwitchFix.RETRY, MacSwitches.macBlock(ready.copy(reach = ShellReach.UNREACHABLE), allowed, null)?.fix)
        for (reach in ShellReach.entries.filter { it != ShellReach.READY }) assertNotNull(reach.name, MacSwitches.macBlock(ready.copy(reach = reach), allowed, null))
        assertNotNull(MacSwitches.macBlock(ready, null, null))
        assertTrue(MacSwitches.macBlock(ready, allowed.copy(control = false), null)!!.text.contains("Awake & VPN"))
        assertNotNull(MacSwitches.macBlock(ready, allowed, MacControlError.NOT_ALLOWED))
    }

    @Test fun blockedSwitchesStayOffAndDisabled() {
        val awake = MacSwitches.awake(allowed, blocked = true, macName = "Studio")
        assertFalse(awake.enabled)
        assertFalse(awake.on)
        assertFalse(MacSwitches.vpn(allowed, blocked = true, macName = "Studio").enabled)
        assertFalse(MacSwitches.awake(null, blocked = false, macName = "Studio").enabled)
    }

    @Test fun noVpnOnTheMac() {
        val vpn = MacSwitches.vpn(allowed.copy(vpn = null), blocked = false, macName = "Studio")
        assertFalse(vpn.enabled)
        assertTrue(vpn.note!!.text.contains("no VPN"))
        assertFalse(MacSwitches.vpn(allowed, blocked = false, macName = "Studio", error = MacControlError.VPN_NOT_SET_UP).enabled)
    }

    @Test fun awakeAtALimitThatStillHolds() {
        val battery = MacSwitches.awake(allowed.copy(awakeStopped = MacStates.STOPPED_BATTERY, batteryFloor = 0.2, charging = false), blocked = false, macName = "Studio")
        assertFalse(battery.enabled)
        assertTrue(battery.note!!.text.contains("20%"))
        // Plugged in since: it can turn back on.
        assertTrue(MacSwitches.awake(allowed.copy(awakeStopped = MacStates.STOPPED_BATTERY, charging = true), blocked = false, macName = "Studio").enabled)
        assertFalse(MacSwitches.awake(allowed.copy(awakeStopped = MacStates.STOPPED_HEAT, hot = true), blocked = false, macName = "Studio").enabled)
        assertTrue(MacSwitches.awake(allowed.copy(awakeStopped = MacStates.STOPPED_HEAT, hot = false), blocked = false, macName = "Studio").enabled)
    }

    /** A change on its way shows as made, with a spinner; one that couldn't be sent says so under its own switch. */
    @Test fun pendingAndUnsent() {
        val turning = MacSwitches.awake(allowed, blocked = false, macName = "Studio", pending = listOf(MacControl.Awake(true)))
        assertTrue(turning.on)
        assertTrue(turning.pending)
        assertEquals("Turning on…", turning.status)

        val unsent = MacSwitches.vpn(allowed, blocked = false, macName = "Studio", error = MacControlError.NOT_SENT, lastTapped = MacSwitch.VPN)
        assertEquals(SwitchFix.RETRY, unsent.note?.fix)
        assertNull(MacSwitches.awake(allowed, blocked = false, macName = "Studio", error = MacControlError.NOT_SENT, lastTapped = MacSwitch.VPN).note)
    }

    @Test fun vpnFailedWarns() {
        val failed = MacSwitches.vpn(allowed.copy(vpn = MacStates.VPN_FAILED, killSwitch = true), blocked = false, macName = "Studio")
        assertTrue(failed.on)
        assertTrue(failed.note!!.warning)
        assertTrue(failed.note!!.text.contains("kill switch"))
    }
}
