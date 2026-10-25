package dev.dpatel.passthrough.core

/** A change a phone asks the Mac for (`setAwake`, `setVPN`). */
sealed interface MacControl {
    val on: Boolean

    data class Awake(override val on: Boolean) : MacControl
    data class Vpn(override val on: Boolean) : MacControl
}

/** The VPN is on, on its way, or failed with its block in place: anything but off. */
val MacState.vpnUp: Boolean get() = vpn == MacStates.VPN_ON || vpn == MacStates.VPN_CONNECTING || vpn == MacStates.VPN_FAILED

/** The moment the Mac is in. [phoneSharing] stands in for `internet` on a Mac that doesn't send it (an older build). */
fun MacState.moment(phoneSharing: Boolean): Moment = Moment.current(internet ?: phoneSharing, awake == true, vpnUp)

/** No battery: a desktop Mac, with no lid to close. */
val MacState.hasLid: Boolean get() = battery != null

/** Running and quiet on a question: "needs you". */
val ShellSessionInfo.isAsking: Boolean get() = running && waiting != null

/** What happened on a Mac since a time (Unix seconds), as it last said. */
data class MacTimeline(val since: Double, val events: List<MacEvent>, val battery: List<BatterySample>, val loadedAt: Double)

/**
 * Where you are, rather than which switches to flip: Internet (the Mac online
 * through a phone, [MacState.internet]), Keep awake and the VPN together. Read
 * off the switches as they are, so a change made on the Mac shows here too;
 * any other mix is [CUSTOM]. Away leaves the VPN as it is, so stepping away
 * never asks for a biometric. Mirrors Moment in PassthroughCore.
 */
enum class Moment(val title: String) {
    DESK("Desk"),
    AWAY("Away"),
    PUBLIC("Public"),
    CUSTOM("Custom");

    /** [phone] names the phone as the reader knows it ("this phone"); [fromAnywhere]: the Mac's shell is reachable off its network. */
    fun caption(phone: String, fromAnywhere: Boolean = true): String = when (this) {
        DESK -> "Online through $phone over the cable. The Mac sleeps as usual."
        AWAY -> "The Mac stays awake on its own Wi-Fi, reachable ${if (fromAnywhere) "from anywhere" else "on its network"}. The VPN stays as it is."
        PUBLIC -> "Online through $phone, with everything going through the VPN."
        CUSTOM -> "Your own mix of the switches below."
    }

    /** Internet, Keep awake, VPN (null: left as it is); null for [CUSTOM]. */
    data class Switches(val internet: Boolean, val awake: Boolean, val vpn: Boolean?)

    val switches: Switches?
        get() = when (this) {
            DESK -> Switches(internet = true, awake = false, vpn = false)
            AWAY -> Switches(internet = false, awake = true, vpn = null)
            PUBLIC -> Switches(internet = true, awake = false, vpn = true)
            CUSTOM -> null
        }

    /** What picking this moment changes from the switches as they are; null for [CUSTOM]. Every app applies a moment through this. */
    fun plan(internet: Boolean, awake: Boolean, vpn: Boolean): MomentPlan? {
        val s = switches ?: return null
        return MomentPlan(
            internet = s.internet.takeIf { it != internet },
            awake = s.awake.takeIf { it != awake },
            vpn = s.vpn?.takeIf { it != vpn },
        )
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

/** The switches a moment changes; null where one is already right or left alone. Mirrors MomentPlan in PassthroughCore. */
data class MomentPlan(val internet: Boolean? = null, val awake: Boolean? = null, val vpn: Boolean? = null) {
    /** Turns the VPN off: asks for the biometric first. */
    val lowersVpn: Boolean get() = vpn == false
    /** Lets the Mac sleep: warns first when shells are running. */
    val letsSleep: Boolean get() = awake == false
    val needsVpn: Boolean get() = vpn == true
    val isEmpty: Boolean get() = internet == null && awake == null && vpn == null
}
