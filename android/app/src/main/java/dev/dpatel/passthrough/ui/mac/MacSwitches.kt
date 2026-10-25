package dev.dpatel.passthrough.ui.mac

import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacFormat
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.hasLid
import dev.dpatel.passthrough.core.vpnUp
import dev.dpatel.passthrough.service.ServiceState
import dev.dpatel.passthrough.ui.shell.MacControlError
import dev.dpatel.passthrough.ui.shell.ShellReach

/** One of the Mac's own switches this phone can change. */
enum class MacSwitch { AWAKE, VPN }

/** A fix this phone can make for what a note describes. */
enum class SwitchFix(val label: String) {
    PAIR("Pair your Mac"),
    RETRY("Try again"),
    USB_DEBUGGING("Open Developer options"),
}

/**
 * Words under a switch: why it is as it is, or why it can't change, and a
 * [fix] where this phone has one. [warning]: something's wrong, rather than
 * just how things are.
 */
data class SwitchNote(val text: String, val warning: Boolean = true, val fix: SwitchFix? = null)

/**
 * A switch as shown. [on] is what the switch shows (a change on its way
 * shows as made, with [pending]); [enabled] only when tapping it can change
 * something; [status] sits right under its title.
 */
data class SwitchModel(val on: Boolean, val enabled: Boolean, val status: String, val note: SwitchNote? = null, val pending: Boolean = false)

/** How this phone reaches the Mac, as the Mac's switches need it. */
data class MacLink(val paired: Boolean, val reach: ShellReach, val macName: String)

/**
 * The Mac tab's three switches: Internet through this phone (this phone's
 * own sharing), Keep Mac awake and VPN (the Mac's, changed over the shell
 * connection). A switch that can't change says why, never a silent no-op.
 */
object MacSwitches {
    /** [macsOnline]: Macs online through this phone now; [elsewhere]: the Mac says it's online through a phone, but not this one. */
    fun internet(service: ServiceState, macsOnline: Int, paired: Boolean, usbDebugging: Boolean, elsewhere: Boolean = false): SwitchModel {
        val usbOff = SwitchNote(
            "USB debugging is off, so your Mac can't reach this phone. Turn it on in Developer options " +
                "(tap Build number seven times in About phone to reveal them).",
            fix = SwitchFix.USB_DEBUGGING,
        )
        return when (service) {
            ServiceState.Running -> SwitchModel(
                on = true, enabled = true,
                status = when (macsOnline) {
                    0 -> "Sharing — waiting for the Mac"
                    1 -> "Mac online through this phone"
                    else -> "$macsOnline Macs online through this phone"
                },
                note = when {
                    !usbDebugging -> usbOff
                    !paired -> SwitchNote("Pair your Mac so it can use this phone's connection.", warning = false, fix = SwitchFix.PAIR)
                    macsOnline == 0 -> SwitchNote("Plug this phone into your Mac with a USB cable, then pick it in Passthrough's menu bar on the Mac.", warning = false)
                    else -> null
                },
            )
            ServiceState.Starting -> SwitchModel(on = true, enabled = false, status = "Starting…", pending = true)
            ServiceState.Stopping -> SwitchModel(on = false, enabled = false, status = "Stopping…", pending = true)
            is ServiceState.Failed -> SwitchModel(
                on = false, enabled = true, status = "Couldn't start",
                note = SwitchNote(service.message.trimEnd('.') + ".", fix = SwitchFix.RETRY),
            )
            ServiceState.Stopped -> SwitchModel(
                on = false, enabled = true, status = "Off",
                note = when {
                    !usbDebugging -> usbOff
                    elsewhere -> SwitchNote("Your Mac is online through another phone.", warning = false)
                    else -> SwitchNote("Your Mac uses its own connection. Turn this on to put it online through this phone.", warning = false)
                },
            )
        }
    }

    /**
     * Why neither Keep awake nor the VPN can change from here, said once for
     * both; null when they can. [error]: the Mac refused a change.
     */
    fun macBlock(link: MacLink, state: MacState?, error: MacControlError?): SwitchNote? {
        val mac = link.macName
        return when {
            !link.paired -> SwitchNote("Keep awake and the VPN can be changed from here once your Mac is paired.", warning = false, fix = SwitchFix.PAIR)
            link.reach == ShellReach.CONNECTING -> SwitchNote("Connecting to $mac…", warning = false)
            link.reach == ShellReach.UNREACHABLE -> SwitchNote("Keep awake and the VPN can't change while $mac can't be reached.", fix = SwitchFix.RETRY)
            link.reach == ShellReach.NO_ACCESS -> SwitchNote(
                "To change Keep awake and the VPN from here, turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once.",
                warning = false,
            )
            link.reach != ShellReach.READY -> SwitchNote(link.reach.message ?: "Keep awake and the VPN can't change from this phone.")
            state == null -> SwitchNote("Waiting for $mac…", warning = false)
            state.control != true || error == MacControlError.NOT_ALLOWED -> SwitchNote(
                "$mac lets you change Keep awake and the VPN only on the Mac. To change them here, turn on Awake & VPN " +
                    "for this phone in Passthrough's Remote Shell settings on the Mac.",
                warning = false,
            )
            else -> null
        }
    }

    /** [blocked]: [macBlock] said why it can't change; [lastTapped]: the switch a "couldn't send" is about. */
    fun awake(
        state: MacState?, blocked: Boolean, macName: String,
        pending: List<MacControl> = emptyList(), error: MacControlError? = null, lastTapped: MacSwitch? = null,
    ): SwitchModel {
        val change = pending.filterIsInstance<MacControl.Awake>().firstOrNull()
        val on = change?.on ?: (state?.awake == true)
        if (state == null) return SwitchModel(on = false, enabled = false, status = "Not known yet")
        if (blocked) return SwitchModel(on = state.awake == true, enabled = false, status = awakeStatus(state))
        // Off at a limit that still holds: the Mac would refuse, so say so instead of offering it.
        val atLimit = state.awake != true && when (state.awakeStopped) {
            MacStates.STOPPED_BATTERY -> state.charging != true
            MacStates.STOPPED_HEAT -> state.hot == true
            else -> false
        }
        val note = when {
            error == MacControlError.NOT_SENT && lastTapped == MacSwitch.AWAKE ->
                SwitchNote("Couldn't reach $macName, so Keep awake didn't change.", fix = SwitchFix.RETRY)
            state.awake == true -> null
            state.awakeStopped == MacStates.STOPPED_BATTERY -> if (atLimit)
                SwitchNote("It turned off at your ${MacFormat.percent(state.batteryFloor ?: 0.2)} battery limit. Plug $macName in to keep it awake.")
            else SwitchNote("It turned off at the battery limit earlier. It's charging now, so you can turn it back on.", warning = false)
            state.awakeStopped == MacStates.STOPPED_HEAT -> if (atLimit)
                SwitchNote("It turned off because $macName is running hot. Turn it on again once it cools down.")
            else SwitchNote("It turned off earlier because $macName ran hot. It's cooler now.", warning = false)
            else -> null
        }
        return SwitchModel(
            on = on, enabled = !atLimit,
            status = change?.let { if (it.on) "Turning on…" else "Turning off…" } ?: awakeStatus(state),
            note = note, pending = change != null,
        )
    }

    fun vpn(
        state: MacState?, blocked: Boolean, macName: String,
        pending: List<MacControl> = emptyList(), error: MacControlError? = null, lastTapped: MacSwitch? = null,
    ): SwitchModel {
        if (state == null) return SwitchModel(on = false, enabled = false, status = "Not known yet")
        if (state.vpn == null || error == MacControlError.VPN_NOT_SET_UP) return SwitchModel(
            on = false, enabled = false, status = "Not set up",
            note = if (blocked) null else SwitchNote("$macName has no VPN set up. Add one in Passthrough's VPN settings on the Mac.", warning = false),
        )
        if (blocked) return SwitchModel(on = state.vpnUp, enabled = false, status = vpnStatus(state))
        val change = pending.filterIsInstance<MacControl.Vpn>().firstOrNull()
        val note = when {
            error == MacControlError.NOT_SENT && lastTapped == MacSwitch.VPN ->
                SwitchNote("Couldn't reach $macName, so the VPN didn't change.", fix = SwitchFix.RETRY)
            change == null && state.vpn == MacStates.VPN_FAILED -> SwitchNote(
                if (state.killSwitch == true) "The VPN couldn't connect, so the kill switch is holding $macName's traffic. It keeps trying; turn the VPN off to go online without it."
                else "The VPN couldn't connect, so $macName's traffic is going out without it. It keeps trying.",
            )
            else -> null
        }
        return SwitchModel(
            on = change?.on ?: state.vpnUp, enabled = true,
            status = change?.let { if (it.on) "Turning on…" else "Turning off…" } ?: vpnStatus(state),
            note = note, pending = change != null,
        )
    }

    fun awakeStatus(s: MacState): String {
        if (s.awake == true) {
            if (s.charging == true) return "On, plugged in"
            s.minutesLeft?.let { return "On, ${MacFormat.duration(it)} of battery left" }
            return if (s.hasLid) "On, even with the lid closed" else "On"
        }
        return "Off — it sleeps as usual"
    }

    fun vpnStatus(s: MacState): String = when (s.vpn) {
        MacStates.VPN_ON -> s.vpnName?.let { "On, $it" } ?: "On"
        MacStates.VPN_CONNECTING -> "Connecting…"
        MacStates.VPN_FAILED -> if (s.killSwitch == true) "Failed — traffic blocked" else "Failed"
        MacStates.VPN_OFF -> "Off"
        else -> "Not set up"
    }
}
