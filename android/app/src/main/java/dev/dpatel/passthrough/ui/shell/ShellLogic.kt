package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.RemoteShell
import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellKeyStatus
import dev.dpatel.passthrough.core.ShellReplay
import dev.dpatel.passthrough.core.ShellReplayChunk
import dev.dpatel.passthrough.core.ShellSessionInfo

/** Plain-Kotlin pieces of the shell UI (no Android types), so they can be unit tested. */

/** Where Remote shell stands, with the copy the card shows. Mirrors ShellModel.Reach on iOS. */
enum class ShellReach(val message: String?) {
    /** Android 9 or older: no TLS 1.3. */
    UNSUPPORTED("Remote shell needs Android 10 or later."),
    /** No Mac has granted this phone the shell (or the Mac refused the key). */
    NO_ACCESS("Turn on Remote shell in Passthrough on your Mac, then connect this phone with the cable once."),
    /** Keys exist but can't be read until the app is unlocked. */
    LOCKED(ShellKeyStatus.LOCKED.message),
    /** The device has no secure lock screen, so the vault can't hold the keys. */
    NEEDS_PASSCODE(ShellKeyStatus.NEEDS_PASSCODE.message),
    /** A key stays unreadable even right after a fresh unlock, or the vault lost it. */
    KEY_UNAVAILABLE(ShellKeyStatus.KEY_UNAVAILABLE.message),
    CONNECTING(null),
    UNREACHABLE("Can't reach your Mac. Use the same Wi-Fi, or turn on Tailscale on both devices."),
    READY(null);

    /** What to tell the user; [fromAnywhere] when this connect also tried the built-in path (iroh). */
    fun message(fromAnywhere: Boolean): String? =
        if (this == UNREACHABLE && fromAnywhere) "Can't reach your Mac. Check that Remote shell is on and the Mac is awake." else message

    companion object {
        /**
         * What to show when the selected Mac has no usable credential: nothing
         * granted → [NO_ACCESS]; a key that needed authentication even after the
         * relock, or a vault whose key was invalidated → [KEY_UNAVAILABLE].
         */
        fun withoutCredential(granting: Boolean, anyLocked: Boolean, keyLost: Boolean): ShellReach = when {
            !granting -> NO_ACCESS
            anyLocked || keyLost -> KEY_UNAVAILABLE
            else -> NO_ACCESS
        }

        /** Before keys are read: the device itself rules the shell out. */
        fun beforeKeys(supported: Boolean, unlocked: Boolean, deviceSecure: Boolean, granting: Boolean): ShellReach? = when {
            !supported -> UNSUPPORTED
            !unlocked -> if (granting) LOCKED else NO_ACCESS
            !deviceSecure -> if (granting) NEEDS_PASSCODE else NO_ACCESS
            else -> null
        }
    }
}

/** Copy for a refusal worth telling the user about; null for ones the UI handles quietly. */
fun ShellError.message(): String? = when (this) {
    ShellError.TOO_MANY_SESSIONS -> "Your Mac already has ${RemoteShell.MAX_SESSIONS} sessions open. End one to start another."
    else -> null
}

/**
 * The sessions this phone knows have ended, from the Mac's `ended` message and
 * from `sessions` entries with `running == false` (the Mac keeps ended sessions
 * listed for a while). An ended session's terminal is a read-only log of its
 * output. Mirrors ShellEndedSessions in PassthroughCore (Swift).
 */
data class ShellEndedSessions(
    /** Exit status per ended session; null when the Mac didn't say. */
    val exits: Map<String, Int?> = emptyMap(),
) {
    /** The Mac said [id] ended. A negative status means it gave none (real ones are 0..255, or 128 + signal). */
    fun ended(id: String, exitStatus: Int?): ShellEndedSessions {
        val status = exitStatus?.takeIf { it >= 0 }
        // Don't lose a status already known from the list to a message without one.
        if (status == null && id in exits) return this
        return copy(exits = exits + (id to status))
    }

    /**
     * Takes in the Mac's session list: entries no longer running have ended.
     * Ended sessions the Mac stopped listing are forgotten unless in [keeping]
     * (a tab still showing its log).
     */
    fun apply(list: List<ShellSessionInfo>, keeping: Set<String> = emptySet()): ShellEndedSessions {
        val listed = list.map { it.id }.toSet()
        var next = ShellEndedSessions(exits.filterKeys { it in listed || it in keeping })
        for (info in list) {
            next = if (info.running) next.forget(info.id) else next.ended(info.id, info.exitStatus)
        }
        return next
    }

    /** The tab was closed: nothing to remember about it. */
    fun forget(id: String): ShellEndedSessions = if (id in exits) copy(exits = exits - id) else this

    fun isEnded(id: String): Boolean = id in exits

    /** The exit status of an ended session, if the Mac gave one. */
    fun exitStatus(id: String): Int? = exits[id]

    /**
     * Whether the terminal showing [id] takes input: not once it ended or its
     * tab was closed. Nothing shown yet (a session still opening) counts as
     * writable: there's no log to protect.
     */
    fun isWritable(id: String?, openTabs: List<String>): Boolean = id == null || (id in openTabs && !isEnded(id))

    /** The banner over an ended session's log; null while it runs. */
    fun banner(id: String): String? = if (isEnded(id)) banner(exitStatus(id)) else null

    companion object {
        fun banner(exitStatus: Int?): String =
            if (exitStatus == null || exitStatus < 0) "Session closed — read-only" else "Session ended (exit $exitStatus) — read-only"
    }
}

object ShellFormat {
    /** "running · 4m" (since it started) or "exited 0 · 1h" (since its last output). Times in Unix seconds. */
    fun status(session: ShellSessionInfo, nowSeconds: Double): String {
        if (session.running) return "running · " + age(nowSeconds - session.startedAt)
        val exited = session.exitStatus?.let { "exited $it" } ?: "exited"
        return exited + " · " + age(nowSeconds - session.lastOutputAt)
    }

    fun age(seconds: Double): String {
        val s = maxOf(0L, seconds.toLong())
        return when {
            s < 60 -> "<1m"
            s < 3600 -> "${s / 60}m"
            s < 86_400 -> "${s / 3600}h"
            else -> "${s / 86_400}d"
        }
    }

    /** The status part of a history row: running, exited N, ended, or interrupted (the Mac stopped mid-session). */
    fun historyStatus(entry: ShellHistoryEntry, running: Boolean): String = when {
        running -> "running"
        entry.endedAt != null -> entry.exitStatus?.let { "exited $it" } ?: "ended"
        else -> "interrupted"
    }

    /**
     * A replay to show: as received, or, from an older Mac that sends no sizes,
     * starting at the session's recorded size when the entry has one.
     */
    fun replayWithStartSize(replay: List<ShellReplayChunk>, entry: ShellHistoryEntry?): List<ShellReplayChunk> {
        if (ShellReplay.largestGrid(replay) != null) return replay
        val cols = entry?.cols ?: return replay
        val rows = entry.rows ?: return replay
        return if (ShellReplay.isValid(cols, rows)) listOf(ShellReplayChunk.Resize(cols, rows)) + replay else replay
    }
}

/** The keys in the row above the keyboard. */
enum class ExtraKey(val label: String?, val description: String) {
    ESC("esc", "Escape"),
    CTRL("ctrl", "Control"),
    TAB("tab", "Tab"),
    LEFT(null, "Left arrow"),
    UP(null, "Up arrow"),
    DOWN(null, "Down arrow"),
    RIGHT(null, "Right arrow"),
    PIPE("|", "Pipe"),
    TILDE("~", "Tilde"),
    PASTE(null, "Paste");

    val isArrow: Boolean get() = this == LEFT || this == UP || this == DOWN || this == RIGHT
}

/** Bytes a terminal sends for keys, as xterm does. */
object TerminalKeys {
    private const val ESC = 0x1b

    /** The control character for [codePoint] (ctrl-a → 1, ctrl-[ → ESC, ctrl-space → 0); others unchanged. */
    fun ctrl(codePoint: Int): Int = when (codePoint) {
        in 'a'.code..'z'.code -> codePoint - 'a'.code + 1
        in 'A'.code..'Z'.code -> codePoint - 'A'.code + 1
        ' '.code, '2'.code -> 0
        '['.code, '3'.code -> 27
        '\\'.code, '4'.code -> 28
        ']'.code, '5'.code -> 29
        '^'.code, '6'.code -> 30
        '_'.code, '7'.code, '/'.code -> 31
        '8'.code -> 127
        else -> codePoint
    }

    /** UTF-8 for [codePoint], after ESC when [alt]; invalid code points become U+FFFD. */
    fun encode(codePoint: Int, alt: Boolean = false): ByteArray {
        val valid = codePoint in 0..0x10FFFF && codePoint !in 0xD800..0xDFFF
        val text = String(Character.toChars(if (valid) codePoint else 0xFFFD))
        val utf8 = text.toByteArray(Charsets.UTF_8)
        return if (alt) byteArrayOf(ESC.toByte()) + utf8 else utf8
    }

    /** A code point as typed, with the ctrl modifier applied first. */
    fun typed(codePoint: Int, ctrl: Boolean, alt: Boolean = false): ByteArray =
        encode(if (ctrl) ctrl(codePoint) else codePoint, alt)

    /**
     * An arrow: `ESC [ A` normally, `ESC O A` in application cursor mode,
     * `ESC [ 1 ; 5 A` with ctrl (either mode).
     */
    fun arrow(key: ExtraKey, applicationCursor: Boolean, ctrl: Boolean): ByteArray {
        val letter = when (key) {
            ExtraKey.UP -> 'A'
            ExtraKey.DOWN -> 'B'
            ExtraKey.RIGHT -> 'C'
            ExtraKey.LEFT -> 'D'
            else -> throw IllegalArgumentException("not an arrow: $key")
        }
        val seq = when {
            ctrl -> "\u001b[1;5$letter"
            applicationCursor -> "\u001bO$letter"
            else -> "\u001b[$letter"
        }
        return seq.toByteArray(Charsets.US_ASCII)
    }

    /** What a key-row key sends; null for ctrl, which only latches. */
    fun extraKey(key: ExtraKey, applicationCursor: Boolean, ctrl: Boolean): ByteArray? = when (key) {
        ExtraKey.CTRL, ExtraKey.PASTE -> null
        ExtraKey.ESC -> byteArrayOf(ESC.toByte())
        ExtraKey.TAB -> byteArrayOf(0x09)
        ExtraKey.PIPE -> typed('|'.code, ctrl)
        ExtraKey.TILDE -> typed('~'.code, ctrl)
        ExtraKey.LEFT, ExtraKey.UP, ExtraKey.DOWN, ExtraKey.RIGHT -> arrow(key, applicationCursor, ctrl)
    }
}

/**
 * Finds [query] (ignoring case) in [lines], starting after (or before) the
 * match at [from]. Returns (line, column) or null. Wraps around once.
 */
fun findInLines(lines: List<String>, query: String, from: Pair<Int, Int>?, forward: Boolean): Pair<Int, Int>? {
    if (query.isEmpty() || lines.isEmpty()) return null
    val n = lines.size
    if (forward) {
        val (startLine, startCol) = from?.let { it.first to it.second + 1 } ?: (0 to 0)
        for (step in 0..n) {
            val line = (startLine + step) % n
            val col = if (step == 0) startCol else 0
            val i = lines[line].indexOf(query, col.coerceAtMost(lines[line].length), ignoreCase = true)
            if (i >= 0) return line to i
        }
    } else {
        val (startLine, startCol) = from?.let { it.first to it.second - 1 } ?: (n - 1 to Int.MAX_VALUE)
        for (step in 0..n) {
            val line = ((startLine - step) % n + n) % n
            val col = if (step == 0) startCol else Int.MAX_VALUE
            if (col < 0) continue
            val i = lines[line].lastIndexOf(query, col.coerceAtMost(lines[line].length), ignoreCase = true)
            if (i >= 0) return line to i
        }
    }
    return null
}
