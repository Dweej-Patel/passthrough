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

    /** Picking a moment changes only what differs, and says when it lowers protection or lets the Mac sleep. */
    @Test fun planChangesOnlyWhatDiffers() {
        assertEquals(MomentPlan(), Moment.DESK.plan(internet = true, awake = false, vpn = false))
        assertTrue(Moment.DESK.plan(internet = true, awake = false, vpn = false)!!.isEmpty)

        val fromPublic = Moment.DESK.plan(internet = true, awake = false, vpn = true)!!
        assertEquals(MomentPlan(vpn = false), fromPublic)
        assertTrue(fromPublic.lowersVpn)
        assertFalse(fromPublic.letsSleep)

        val fromAway = Moment.PUBLIC.plan(internet = false, awake = true, vpn = false)!!
        assertEquals(MomentPlan(internet = true, awake = false, vpn = true), fromAway)
        assertTrue(fromAway.letsSleep)
        assertTrue(fromAway.needsVpn)
        assertFalse(fromAway.lowersVpn)

        // Away leaves the VPN alone.
        assertEquals(MomentPlan(internet = false, awake = true), Moment.AWAY.plan(internet = true, awake = false, vpn = true))
        assertNull(Moment.CUSTOM.plan(internet = true, awake = true, vpn = true))
    }

    /** A Mac that says where it's online is read the same by every phone; an older one falls back to this phone sharing. */
    @Test fun momentFromMacState() {
        val away = MacState(awake = true, vpn = MacStates.VPN_OFF, internet = false)
        assertEquals(Moment.AWAY, away.moment(phoneSharing = true))
        assertEquals(Moment.DESK, MacState(awake = false, vpn = MacStates.VPN_OFF).moment(phoneSharing = true))
        assertEquals(Moment.PUBLIC, MacState(awake = false, vpn = MacStates.VPN_ON, internet = true).moment(phoneSharing = false))
    }

    @Test fun captionNamesThePhoneAndTheReach() {
        assertTrue(Moment.DESK.caption("this phone").contains("this phone"))
        assertTrue(Moment.AWAY.caption("the phone").contains("from anywhere"))
        assertTrue(Moment.AWAY.caption("the phone", fromAnywhere = false).contains("on its network"))
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
