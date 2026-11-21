package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.HostWords
import dev.dpatel.passthrough.core.RemoteShell

/**
 * The sentences that differ between a Mac and a PC in more than the noun ([HostWords] has the
 * nouns). Each Mac variant is the sentence the app showed before PCs, unchanged (HostCopyTests
 * holds them); a neutral [HostWords] (a kind this build doesn't know) reads like the Mac's with
 * "computer". Times come in already formatted, so this is plain text. Mirrors HostCopy in
 * PassthroughCore (Swift), with "this phone" for the device.
 */
object HostCopy {
    private fun device(w: HostWords) = "this ${w.device}"

    // Reaching it

    /** Paired, but it has given this phone no access yet. */
    fun noAccess(w: HostWords): String =
        if (w.isPC) "Paired. Turn on Remote access on ${w.name}, then plug ${device(w)} in once."
        else "Turn on Remote shell in Passthrough on ${w.your}, then connect ${device(w)} with the cable once."

    /** It took this phone's access away (`not_authorized` while a key was held). A Mac has always said [noAccess]. */
    fun revoked(w: HostWords): String =
        if (w.isPC) "${w.name} no longer lets ${device(w)} in. Plug it into the PC to get access again."
        else noAccess(w)

    /** The key in this phone's vault can't be read. */
    fun keyUnavailable(w: HostWords): String = "Couldn't read the Remote shell key. Plug into ${w.the} again to renew access."

    /**
     * Can't reach it, cause unknown. [fromAnywhere]: this connect also tried the built-in path
     * (iroh). [lastHeard]: when it last answered, formatted, if known (a PC's sentence says it).
     */
    fun unreachable(w: HostWords, fromAnywhere: Boolean, lastHeard: String? = null): String =
        "Can't reach ${if (w.isPC) w.name else w.your}. " + unreachableDetail(w, fromAnywhere, lastHeard)

    /** [unreachable] after its first sentence, for a notice whose title already says it. */
    fun unreachableDetail(w: HostWords, fromAnywhere: Boolean, lastHeard: String? = null): String = when {
        !fromAnywhere -> "Use the same Wi-Fi, or turn on Tailscale on both devices."
        w.isPC -> "It may be asleep, off, or offline." + (lastHeard?.let { " Last heard $it." } ?: "")
        else -> "Check that ${w.feature} is on and ${w.the} is awake."
    }

    /** It said it was going to sleep at [at]; [sleepsAfter] is its sleep timer, formatted, if it has one. */
    fun wentToSleep(w: HostWords, at: String, sleepsAfter: String?): String =
        if (sleepsAfter != null) "${w.name} went to sleep at $at. It sleeps after $sleepsAfter; turn on Stay awake in Passthrough on ${w.the}."
        else "${w.name} went to sleep at $at. Turn on Stay awake in Passthrough on ${w.the} to keep it reachable."

    /** It said Remote access was turned off at [at]. */
    fun turnedOff(w: HostWords, at: String): String = "${w.feature} was turned off on ${w.name} at $at. Turn it on there."

    /** It said it was shutting down at [at]. */
    fun shutDown(w: HostWords, at: String): String =
        "${w.name} was shut down or restarted at $at. It is reachable again once ${if (w.isPC) "Windows" else "it"} has started."

    /** Tried from anywhere, and its relay didn't answer. */
    fun noRelay(w: HostWords): String =
        "Can't reach ${w.name} from here. The relay isn't answering; it works on ${w.the}'s own network or Tailscale."

    /** The page's headline for [state] (a Mac's page keeps its own titles; this is a PC's). */
    fun title(state: HostPageState, online: Boolean = false): String = when (state) {
        HostPageState.CONNECTED -> "Reachable"
        HostPageState.CONNECTING -> "Connecting…"
        HostPageState.RECONNECTING -> "Reconnecting…"
        HostPageState.UNREACHABLE -> "Can't reach it"
        HostPageState.WENT_TO_SLEEP -> "Asleep"
        HostPageState.TURNED_OFF -> "Remote access is off"
        HostPageState.SHUT_DOWN -> "Shut down"
        HostPageState.NO_RELAY -> "Can't reach it from here"
        HostPageState.REVOKED -> "No access"
        HostPageState.PAIRED_NO_ACCESS -> if (online) "Plugged in" else "Paired"
        HostPageState.LOCKED -> "Unlock to continue"
        HostPageState.NEEDS_PASSCODE -> "Set a screen lock"
        HostPageState.KEY_UNAVAILABLE -> "Plug in to renew access"
        HostPageState.UNSUPPORTED -> "Not on this phone"
    }

    /**
     * The sentence under the title while it can't be reached (for the farewells, [at] is when it
     * said so, formatted); null in the states that have none.
     */
    fun detail(state: HostPageState, w: HostWords, fromAnywhere: Boolean, lastHeard: String?, at: String?, sleepsAfter: String?): String? = when (state) {
        HostPageState.UNREACHABLE -> unreachable(w, fromAnywhere, lastHeard)
        HostPageState.WENT_TO_SLEEP -> wentToSleep(w, at.orEmpty(), sleepsAfter)
        HostPageState.TURNED_OFF -> turnedOff(w, at.orEmpty())
        HostPageState.SHUT_DOWN -> shutDown(w, at.orEmpty())
        HostPageState.NO_RELAY -> noRelay(w)
        HostPageState.REVOKED -> revoked(w)
        HostPageState.PAIRED_NO_ACCESS -> noAccess(w)
        HostPageState.KEY_UNAVAILABLE -> keyUnavailable(w)
        else -> null
    }

    // Shells

    /** Why no shell can start there now; null when one can. */
    fun shell(state: HostShellState, w: HostWords): String? = when (state) {
        HostShellState.AVAILABLE -> null
        HostShellState.NOBODY_SIGNED_IN -> "Sign in to ${w.name} to use its shell."
        HostShellState.SOMEONE_ELSE_SIGNED_IN -> "Someone else is signed in to ${w.name}. Its shell starts when you sign in."
        HostShellState.APP_NOT_OPEN -> "Passthrough isn't open on ${w.name}. Open it there."
        HostShellState.SWITCHED_OFF -> "${w.name} doesn't let ${device(w)} open shells. Turn on Shell for it in ${w.settingsPlace}."
    }

    fun tooManySessions(w: HostWords): String = "${w.Your} already has ${RemoteShell.MAX_SESSIONS} sessions open. End one to start another."

    fun connecting(w: HostWords, named: String?, redialing: Boolean): String =
        "${if (redialing) "Reconnecting" else "Connecting"} to ${named ?: w.your}…"

    fun noSessions(w: HostWords): String = "No sessions open on ${w.thisOne}. Tap New to start one."

    fun nothingRunning(name: String): String = "Nothing running. Start a shell to run commands on $name."

    fun setupIntro(w: HostWords): String = "Open ${w.your}'s shell from ${device(w)}. To set it up:"

    /** The notice title when it can't be reached; [named]: the card names it on the line above. */
    fun cantReachTitle(w: HostWords, named: Boolean): String = if (named) "Can't reach ${w.thisOne}" else "Can't reach ${w.your}"

    fun renewKey(w: HostWords): String =
        "This ${w.device}'s Remote shell key can't be read. Start the proxy and plug into ${w.the} again to renew access."

    /**
     * What to do, in order, before it has given this phone a shell. A PC's own steps; a Mac's
     * are today's; with nothing paired ([w] neutral), the steps for either.
     */
    fun setupSteps(w: HostWords, paired: Boolean): List<String> = when {
        w.isPC -> listOf(
            if (paired) "Pair ${device(w)} with your PC. Done." else "Pair ${device(w)} with your PC: tap Pair a Mac or PC, then type the code in Passthrough on the PC.",
            "Turn on Remote access on your PC: open Passthrough's Settings there, go to Remote access and choose Turn on. Windows asks for an administrator once.",
            "Start sharing with the power button on This phone, then plug ${device(w)} into the PC.",
        )
        w.isMac -> listOf(
            "On your Mac, open Passthrough from the menu bar and turn on Remote shell.",
            "Start the proxy here and plug ${device(w)} into the Mac (pair it first if needed). The Mac sends ${device(w)} a key.",
            "That's it: your Mac's sessions show up here, over Wi-Fi, Tailscale or from anywhere.",
        )
        else -> listOf(
            "Pair ${device(w)} with your Mac or PC.",
            "Turn on Remote shell (Mac) or Remote access (PC) there.",
            "Start sharing here, then plug ${device(w)} in once.",
        )
    }

    // Screen (Android has no screen view: a PC's row says why)

    fun screen(state: HostScreenState, w: HostWords): String? = when (state) {
        HostScreenState.AVAILABLE, HostScreenState.NONE -> null
        HostScreenState.NOT_IN_THIS_VERSION -> "${w.name}'s screen isn't in this version of Passthrough yet. Its shell works."
        HostScreenState.SWITCHED_OFF -> "Screen is off for ${device(w)}. On ${w.name}, open Passthrough's settings and turn on Screen for it."
        HostScreenState.REMOTE_DESKTOP_OFF -> "Remote Desktop is off on ${w.name}. Turn it on in Passthrough's settings there."
        HostScreenState.WINDOWS_HOME -> "${w.name} runs Windows Home, which has no Remote Desktop. The shell works."
        HostScreenState.NO_PASSWORD -> "Your account on ${w.name} has no password Remote Desktop can use. Add one on the PC."
        HostScreenState.REMOTE_DESKTOP_PROBLEM -> "Remote Desktop on ${w.name} needs a look. Open Passthrough's settings on the PC."
    }

    // The rest of the page

    /** Under a PC's switches when it has given this phone nothing yet. */
    fun reachBlockNoAccess(w: HostWords): String = "To use ${w.name} from ${device(w)}, turn on Remote access there. The steps are below."

    fun lockStatus(locked: Boolean, asked: Boolean, w: HostWords): String = when {
        asked && !locked -> "Locking…"
        locked -> if (w.isPC) "Locked — its shells keep running" else "Locked — everything keeps running"
        else -> "Unlocked"
    }

    /** The Activity tab for a computer that keeps no timeline. */
    fun noTimeline(w: HostWords): String? = if (w.isPC) "A PC keeps no timeline yet." else null
}
