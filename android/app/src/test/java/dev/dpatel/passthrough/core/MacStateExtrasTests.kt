package dev.dpatel.passthrough.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors MacStateExtrasTests in PassthroughCore: both phones read the Mac's state the same way. */
class MacStateExtrasTests {
    @Test fun vpnUp() {
        assertFalse(MacState(vpn = MacStates.VPN_OFF).vpnUp)
        assertFalse(MacState().vpnUp)
        for (state in listOf(MacStates.VPN_ON, MacStates.VPN_CONNECTING, MacStates.VPN_FAILED)) assertTrue(state, MacState(vpn = state).vpnUp)
    }

    @Test fun lidOnlyWithABattery() {
        assertTrue(MacState(battery = 0.5).hasLid)
        assertFalse(MacState().hasLid)
    }

    @Test fun format() {
        assertEquals("3 h 10 m", MacFormat.duration(190))
        assertEquals("45 m", MacFormat.duration(45))
        assertEquals("83%", MacFormat.percent(0.825))
    }

    @Test fun asking() {
        assertTrue(ShellSessionInfo("a", "claude", startedAt = 0.0, lastOutputAt = 0.0, running = true, waiting = "Edit?").isAsking)
        assertFalse(ShellSessionInfo("a", "claude", startedAt = 0.0, lastOutputAt = 0.0, running = false, waiting = "Edit?").isAsking)
        assertFalse(ShellSessionInfo("a", "zsh", startedAt = 0.0, lastOutputAt = 0.0, running = true).isAsking)
    }
}
