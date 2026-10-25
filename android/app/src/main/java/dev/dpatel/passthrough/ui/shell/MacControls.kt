package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.vpnUp

/** Why a Keep awake or VPN change didn't happen. */
enum class MacControlError {
    /** The Mac doesn't let this phone change them (`not_allowed`). */
    NOT_ALLOWED,
    /** The VPN can't turn on: the Mac has none set up (`vpn_not_set_up`). */
    VPN_NOT_SET_UP,
    /** Made while the Mac couldn't be reached, and still couldn't be [MacControls.HOLD_MS] later. */
    NOT_SENT,
}

/**
 * Keep awake and VPN changes on their way to the Mac, one per switch: sent and
 * waiting for the `macState` that shows them (the Mac answers each accepted one
 * within a second or so), or made while it couldn't be reached and held until
 * it can, so a change confirmed behind a system prompt isn't lost. Times are
 * milliseconds. Main-thread only.
 */
class MacControls {
    private class Entry(val change: MacControl, val at: Long, val sent: Boolean)

    private var entries = listOf<Entry>()

    /** Changes the Mac doesn't show yet, sent or held: their switches show a spinner. */
    val pending: List<MacControl> get() = entries.map { it.change }
    var error: MacControlError? = null
        private set

    /** A change asked for, sent at once when [ready], else held for [readied]. Replaces one for the same switch. */
    fun request(change: MacControl, ready: Boolean, now: Long) {
        error = null
        entries = entries.filterNot { it.change::class == change::class } + Entry(change, now, sent = ready)
    }

    /** The connection is ready: the held changes, to send now (each then waits for its answer). */
    fun readied(now: Long): List<MacControl> {
        val held = entries.filterNot { it.sent }.map { it.change }
        entries = entries.map { if (it.sent) it else Entry(it.change, now, sent = true) }
        return held
    }

    /** A `macState`: a change it shows is done; an allowed phone, or a VPN set up, ends the refusal it fixes. */
    fun stateArrived(state: MacState) {
        entries = entries.filterNot { it.sent && shows(state, it.change) }
        if ((error == MacControlError.NOT_ALLOWED && state.control == true) ||
            (error == MacControlError.VPN_NOT_SET_UP && state.vpn != null)) error = null
    }

    /** The Mac refused what was sent ([ShellError.NOT_ALLOWED] or [ShellError.VPN_NOT_SET_UP]). */
    fun refused(reason: ShellError) {
        val e = when (reason) {
            ShellError.NOT_ALLOWED -> MacControlError.NOT_ALLOWED
            ShellError.VPN_NOT_SET_UP -> MacControlError.VPN_NOT_SET_UP
            else -> return
        }
        entries = entries.filterNot { it.sent && (e == MacControlError.NOT_ALLOWED || it.change is MacControl.Vpn) }
        error = e
    }

    /** The connection ended: no answer comes for what was sent. Held changes stay. */
    fun disconnected() {
        entries = entries.filterNot { it.sent }
    }

    /** Stops waiting for an answer after [ANSWER_MS], and gives up on a held change after [HOLD_MS], saying so. */
    fun expire(now: Long) {
        if (entries.any { !it.sent && now - it.at >= HOLD_MS }) error = MacControlError.NOT_SENT
        entries = entries.filter { now - it.at < if (it.sent) ANSWER_MS else HOLD_MS }
    }

    fun reset() {
        entries = emptyList()
        error = null
    }

    private fun shows(state: MacState, change: MacControl): Boolean = when (change) {
        // Refused at the battery limit or when hot: the Mac says why instead.
        is MacControl.Awake -> (state.awake == true) == change.on || (change.on && state.awakeStopped != null)
        is MacControl.Vpn -> state.vpn == null || state.vpnUp == change.on
    }

    companion object {
        const val ANSWER_MS = 8_000L
        const val HOLD_MS = 30_000L
    }
}
