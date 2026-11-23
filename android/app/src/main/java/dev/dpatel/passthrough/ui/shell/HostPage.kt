package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.HostFarewell
import dev.dpatel.passthrough.core.HostInfo
import dev.dpatel.passthrough.core.HostKind
import dev.dpatel.passthrough.core.ShellError

/** Whether the relay a computer reaches this phone through answered, after a connect from anywhere failed. */
enum class RelayHealth { UNKNOWN, ANSWERING, SILENT }

/** Where the page stands with the selected computer. */
enum class HostPageState {
    CONNECTED, CONNECTING, RECONNECTING,
    /** Can't reach it, cause unknown. */
    UNREACHABLE,
    /** It said why it left (going away) before the connection dropped. */
    WENT_TO_SLEEP, TURNED_OFF, SHUT_DOWN,
    /** Tried from anywhere, and the relay didn't answer. */
    NO_RELAY,
    /** It took this phone's access away. */
    REVOKED,
    /** Paired, and nothing granted yet. */
    PAIRED_NO_ACCESS,
    /** This phone's own reasons. */
    LOCKED, NEEDS_PASSCODE, KEY_UNAVAILABLE, UNSUPPORTED,
}

/** Whether a shell can start there now. */
enum class HostShellState { AVAILABLE, NOBODY_SIGNED_IN, SOMEONE_ELSE_SIGNED_IN, APP_NOT_OPEN, SWITCHED_OFF }

/** What the Screen row says (Android has no screen view, so for a PC it says why). */
enum class HostScreenState {
    /** A Mac (Android shows no Screen row for it), or a PC once this app can show its screen. */
    AVAILABLE,
    /** The computer offers only screens this app can't show. */
    NOT_IN_THIS_VERSION,
    SWITCHED_OFF, REMOTE_DESKTOP_OFF, WINDOWS_HOME, NO_PASSWORD, REMOTE_DESKTOP_PROBLEM,
    /** Nothing offered and no reason given: no row. */
    NONE,
}

/** The screens this app can show, per kind: none on Android. */
object ScreenBackends {
    fun supported(@Suppress("UNUSED_PARAMETER") kind: HostKind?): Set<String> = emptySet()
}

/** What [HostPage.make] reads. Times are Unix millis. */
data class HostPageInput(
    /** Null: a kind this build doesn't know. */
    val kind: HostKind?,
    val reach: ShellReach,
    /** Connecting again by itself after a working connection dropped. */
    val redialing: Boolean = false,
    /** `not_authorized` arrived while this phone held a key. */
    val accessRefused: Boolean = false,
    /** The live `host`, else the last one stored. */
    val host: HostInfo? = null,
    val farewell: HostFarewell? = null,
    val connectingSinceMillis: Long? = null,
    /** This connect also dialed iroh. */
    val triedFromAnywhere: Boolean = false,
    val relay: RelayHealth = RelayHealth.UNKNOWN,
    /** The last `open` was refused with `signed_out` or `not_allowed`. */
    val shellRefusal: ShellError? = null,
    val viewerScreens: Set<String> = ScreenBackends.supported(kind),
    val nowMillis: Long = 0,
)

/**
 * The selected computer's page, from one pure function: where it stands, whether a shell can
 * start, what the Screen row says, and whether Try again is offered. Mirrors HostPage in
 * PassthroughCore (Swift). For a Mac the states map onto what the page always showed.
 */
data class HostPage(val state: HostPageState, val shell: HostShellState, val screen: HostScreenState, val canRetry: Boolean) {
    companion object {
        /** How long a connect runs before Try again is offered beside it. */
        const val RETRY_AFTER_MS = 30_000L

        fun make(input: HostPageInput): HostPage {
            var canRetry = false
            val state = when (input.reach) {
                ShellReach.LOCKED -> HostPageState.LOCKED
                ShellReach.NEEDS_PASSCODE -> HostPageState.NEEDS_PASSCODE
                ShellReach.KEY_UNAVAILABLE -> HostPageState.KEY_UNAVAILABLE
                ShellReach.UNSUPPORTED -> HostPageState.UNSUPPORTED
                ShellReach.NO_ACCESS -> if (input.accessRefused) HostPageState.REVOKED else HostPageState.PAIRED_NO_ACCESS
                ShellReach.READY -> HostPageState.CONNECTED
                ShellReach.CONNECTING -> {
                    canRetry = input.connectingSinceMillis?.let { input.nowMillis - it >= RETRY_AFTER_MS } ?: false
                    if (input.redialing) HostPageState.RECONNECTING else HostPageState.CONNECTING
                }
                ShellReach.UNREACHABLE -> {
                    canRetry = true
                    // Only a computer that says why it leaves (a Mac never does) gets these.
                    val saysWhy = input.kind != HostKind.MAC
                    when {
                        saysWhy && input.farewell?.reason == HostFarewell.SLEEPING -> HostPageState.WENT_TO_SLEEP
                        saysWhy && input.farewell?.reason == HostFarewell.TURNED_OFF -> HostPageState.TURNED_OFF
                        saysWhy && input.farewell?.reason == HostFarewell.SHUTTING_DOWN -> HostPageState.SHUT_DOWN
                        saysWhy && input.triedFromAnywhere && input.relay == RelayHealth.SILENT -> HostPageState.NO_RELAY
                        else -> HostPageState.UNREACHABLE
                    }
                }
            }
            return HostPage(state, shell(input), screen(input), canRetry)
        }

        /** Meaningful while connected. A refusal stands until a newer `host` clears it (the view model does). */
        private fun shell(input: HostPageInput): HostShellState {
            val host = input.host
            if (host?.access?.shell == false || input.shellRefusal == ShellError.NOT_ALLOWED) return HostShellState.SWITCHED_OFF
            if (host?.signedIn == false) {
                return if (host.console == CONSOLE_OTHER_USER) HostShellState.SOMEONE_ELSE_SIGNED_IN else HostShellState.NOBODY_SIGNED_IN
            }
            if (host?.app == false) return HostShellState.APP_NOT_OPEN
            // Refused though the host (if it said anything) looked able: the least specific true sentence.
            if (input.shellRefusal == ShellError.SIGNED_OUT) return HostShellState.APP_NOT_OPEN
            return HostShellState.AVAILABLE
        }

        private fun screen(input: HostPageInput): HostScreenState {
            if (input.kind == HostKind.MAC) return HostScreenState.AVAILABLE
            if (input.kind == null) return HostScreenState.NONE
            val host = input.host ?: return if (input.viewerScreens.isEmpty()) HostScreenState.NOT_IN_THIS_VERSION else HostScreenState.NONE
            val offered = host.screens.orEmpty()
            if (offered.any { it in input.viewerScreens }) return HostScreenState.AVAILABLE
            if (input.viewerScreens.isEmpty() && offered.isNotEmpty()) return HostScreenState.NOT_IN_THIS_VERSION
            return when (host.rdp) {
                "edition" -> HostScreenState.WINDOWS_HOME
                "off" -> HostScreenState.REMOTE_DESKTOP_OFF
                "account" -> HostScreenState.NO_PASSWORD
                "service", "exposed", "policy" -> HostScreenState.REMOTE_DESKTOP_PROBLEM
                else -> if (host.access?.screen == false) HostScreenState.SWITCHED_OFF else HostScreenState.NONE
            }
        }

        private const val CONSOLE_OTHER_USER = "otherUser"
    }
}
