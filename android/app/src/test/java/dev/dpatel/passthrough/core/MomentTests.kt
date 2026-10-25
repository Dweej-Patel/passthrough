package dev.dpatel.passthrough.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors MomentTests in PassthroughCore: both phones read moments the same way. */
class MomentTests {
    @Test fun eachMomentIsReadOffItsSwitches() {
        assertEquals(Moment.DESK, Moment.current(internet = true, awake = false, vpn = false))
        assertEquals(Moment.PUBLIC, Moment.current(internet = true, awake = false, vpn = true))
        assertEquals(Moment.AWAY, Moment.current(internet = false, awake = true, vpn = false))
    }

    @Test fun awayHoldsWithTheVpnEitherWay() {
        assertEquals(Moment.AWAY, Moment.current(internet = false, awake = true, vpn = true))
        assertNull(Moment.AWAY.switches!!.vpn)
    }

    @Test fun anyOtherMixIsCustom() {
        assertEquals(Moment.CUSTOM, Moment.current(internet = false, awake = false, vpn = false))
        assertEquals(Moment.CUSTOM, Moment.current(internet = true, awake = true, vpn = false))
        assertEquals(Moment.CUSTOM, Moment.current(internet = true, awake = true, vpn = true))
        assertEquals(Moment.CUSTOM, Moment.current(internet = false, awake = false, vpn = true))
        assertNull(Moment.CUSTOM.switches)
        assertFalse(Moment.CUSTOM in Moment.choices)
    }

    @Test fun vpnUp() {
        assertFalse(MacState(vpn = MacStates.VPN_OFF).vpnUp)
        assertFalse(MacState().vpnUp)
        for (state in listOf(MacStates.VPN_ON, MacStates.VPN_CONNECTING, MacStates.VPN_FAILED)) assertTrue(state, MacState(vpn = state).vpnUp)
    }
}
