package dev.dpatel.passthrough.core

/** A change a phone asks the Mac for (`setAwake`, `setVPN`). */
sealed interface MacControl {
    data class Awake(val on: Boolean) : MacControl
    data class Vpn(val on: Boolean) : MacControl
}

/** The `vpn` values in [MacState]. */
object MacStates {
    const val VPN_OFF = "off"
    const val VPN_CONNECTING = "connecting"
    const val VPN_ON = "on"
    const val VPN_FAILED = "failed"
}

/** The VPN is on, on its way, or failed with its block in place: anything but off. */
val MacState.vpnUp: Boolean get() = vpn == MacStates.VPN_ON || vpn == MacStates.VPN_CONNECTING || vpn == MacStates.VPN_FAILED

/** What happened on a Mac since a time (Unix seconds), as it last said. */
data class MacTimeline(val since: Double, val events: List<MacEvent>, val battery: List<BatterySample>, val loadedAt: Double)

/**
 * Where you are, rather than which switches to flip: Internet (through this
 * phone), Keep awake and the VPN together. Read off the switches as they are,
 * so a change made on the Mac shows here too; any other mix is [CUSTOM]. Away
 * leaves the VPN as it is, so stepping away never asks for a biometric.
 * Mirrors Moment in PassthroughCore.
 */
enum class Moment(val title: String, val caption: String) {
    DESK("Desk", "Online through this phone over the cable. The Mac sleeps as usual."),
    AWAY("Away", "The Mac stays awake on its own Wi-Fi, reachable from anywhere. The VPN stays as it is."),
    PUBLIC("Public", "Online through this phone, with everything going through the VPN."),
    CUSTOM("Custom", "Your own mix of the switches below.");

    /** Internet, Keep awake, VPN (null: left as it is); null for [CUSTOM]. */
    data class Switches(val internet: Boolean, val awake: Boolean, val vpn: Boolean?)

    val switches: Switches?
        get() = when (this) {
            DESK -> Switches(internet = true, awake = false, vpn = false)
            AWAY -> Switches(internet = false, awake = true, vpn = null)
            PUBLIC -> Switches(internet = true, awake = false, vpn = true)
            CUSTOM -> null
        }

    companion object {
        val choices = listOf(DESK, AWAY, PUBLIC)

        fun current(internet: Boolean, awake: Boolean, vpn: Boolean): Moment =
            choices.firstOrNull { m ->
                val s = m.switches!!
                s.internet == internet && s.awake == awake && (s.vpn ?: vpn) == vpn
            } ?: CUSTOM
    }
}
