package dev.dpatel.passthrough.core

/** A change a phone asks the Mac for (`setAwake`, `setVPN`). */
sealed interface MacControl {
    val on: Boolean

    data class Awake(override val on: Boolean) : MacControl
    data class Vpn(override val on: Boolean) : MacControl
}

/** The VPN is on, on its way, or failed with its block in place: anything but off. */
val MacState.vpnUp: Boolean get() = vpn == MacStates.VPN_ON || vpn == MacStates.VPN_CONNECTING || vpn == MacStates.VPN_FAILED

/** No battery: a desktop Mac, with no lid to close. */
val MacState.hasLid: Boolean get() = battery != null

/** Running and quiet on a question: "needs you". */
val ShellSessionInfo.isAsking: Boolean get() = running && waiting != null

/** What happened on a Mac since a time (Unix seconds), as it last said. */
data class MacTimeline(val since: Double, val events: List<MacEvent>, val battery: List<BatterySample>, val loadedAt: Double)
