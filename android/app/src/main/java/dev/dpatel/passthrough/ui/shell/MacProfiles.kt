package dev.dpatel.passthrough.ui.shell

import android.text.format.DateUtils
import dev.dpatel.passthrough.core.ShellCredential
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.core.isAsking
import java.text.BreakIterator
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Plain-Kotlin port of Swift's MacProfiles.swift (PassthroughCore). Times are Unix millis here, not Date. */

/** A Mac's open shell tabs and which one was showing. */
@Serializable
data class MacTabs(val openTabs: List<String>, val active: String?)

/** The tabs each paired Mac had open, so switching Macs brings them back. */
@Serializable
data class MacTabMemory(val byMac: Map<String, MacTabs> = emptyMap()) {
    /** Remembers [tabs] for the Mac; nothing open and nothing active forgets it. */
    fun save(tabs: MacTabs, macID: String): MacTabMemory {
        val empty = tabs.openTabs.isEmpty() && tabs.active == null
        return copy(byMac = if (empty) byMac - macID else byMac + (macID to tabs))
    }

    fun tabs(macID: String): MacTabs = byMac[macID] ?: MacTabs(emptyList(), null)

    fun forget(macID: String): MacTabMemory = copy(byMac = byMac - macID)

    /** Drops Macs no longer paired. */
    fun keepOnly(macIDs: Set<String>): MacTabMemory = copy(byMac = byMac.filterKeys { it in macIDs })

    fun toJson(): String = Json.encodeToString(MacTabMemory.serializer(), this)

    companion object {
        fun fromJson(json: String): MacTabMemory = Json.decodeFromString(MacTabMemory.serializer(), json)

        /** What was stored, or nothing remembered when there is none or it can't be read. */
        fun stored(json: String?): MacTabMemory =
            json?.let { runCatching { fromJson(it) }.getOrNull() } ?: MacTabMemory()
    }
}

/** Sessions the phone hid from a Mac's list, per Mac. */
@Serializable
data class ShellHiddenSessions(val byMac: Map<String, Set<String>> = emptyMap()) {
    fun hide(id: String, macID: String): ShellHiddenSessions =
        copy(byMac = byMac + (macID to (byMac[macID].orEmpty() + id)))

    /** Forgets hidden sessions the Mac no longer lists. */
    fun apply(listed: List<String>, macID: String): ShellHiddenSessions {
        val hidden = byMac[macID] ?: return this
        val kept = hidden.intersect(listed.toSet())
        return copy(byMac = if (kept.isEmpty()) byMac - macID else byMac + (macID to kept))
    }

    fun visible(sessions: List<ShellSessionInfo>, macID: String): List<ShellSessionInfo> {
        val hidden = byMac[macID].orEmpty()
        return sessions.filter { it.id !in hidden }
    }

    fun forget(macID: String): ShellHiddenSessions = copy(byMac = byMac - macID)

    /** Only a finished session can be removed: known ended, or listed as not running. A running or unknown one can't. */
    fun canRemove(id: String, ended: ShellEndedSessions, sessions: List<ShellSessionInfo>): Boolean =
        ended.isEnded(id) || sessions.firstOrNull { it.id == id }?.running == false

    /** Drops Macs no longer paired. */
    fun keepOnly(macIDs: Set<String>): ShellHiddenSessions = copy(byMac = byMac.filterKeys { it in macIDs })

    fun toJson(): String = Json.encodeToString(serializer(), this)

    companion object {
        /** What was stored, or nothing hidden when there is none or it can't be read. */
        fun stored(json: String?): ShellHiddenSessions =
            json?.let { runCatching { Json.decodeFromString(serializer(), it) }.getOrNull() } ?: ShellHiddenSessions()
    }
}

/** What a Mac's row in the switcher says about it. */
sealed interface MacStatus {
    /** Reachable; the number of running sessions. */
    data class Connected(val shells: Int) : MacStatus
    data class Asking(val title: String, val question: String) : MacStatus
    /** Last heard at [millis] (Unix millis). */
    data class LastHeard(val millis: Long) : MacStatus
    /** Paired for internet only. */
    object NoShell : MacStatus
    object Connecting : MacStatus
}

object MacProfiles {
    fun status(sessions: List<ShellSessionInfo>?, reachable: Boolean, lastHeardMillis: Long?, hasShell: Boolean): MacStatus {
        if (!hasShell) return MacStatus.NoShell
        val asking = sessions?.firstOrNull { it.isAsking }
        val question = asking?.waiting
        if (asking != null && question != null) return MacStatus.Asking(asking.title, question)
        if (reachable) return MacStatus.Connected(sessions?.count { it.running } ?: 0)
        if (lastHeardMillis != null) return MacStatus.LastHeard(lastHeardMillis)
        return MacStatus.Connecting
    }

    /**
     * [relative] renders a past time against now; production uses Android's
     * DateUtils (localized, like Swift's RelativeDateTimeFormatter). Injected so
     * this stays testable on the JVM, where DateUtils returns null.
     */
    fun statusText(
        status: MacStatus,
        nowMillis: Long,
        relative: (thenMillis: Long, nowMillis: Long) -> String = ::androidRelative,
    ): String = when (status) {
        is MacStatus.Connected -> when (status.shells) {
            0 -> "Connected"
            1 -> "Connected · 1 shell open"
            else -> "Connected · ${status.shells} shells open"
        }
        is MacStatus.Asking -> "${status.title} is asking a question"
        is MacStatus.LastHeard -> "Last heard " + relative(status.millis, nowMillis)
        MacStatus.NoShell -> "Paired, no Remote shell"
        MacStatus.Connecting -> "Connecting…"
    }

    /** The avatar letter: the name's first grapheme cluster, uppercased; "?" without one. */
    fun initial(macName: String): String {
        val trimmed = macName.trim()
        if (trimmed.isEmpty()) return "?"
        val boundaries = BreakIterator.getCharacterInstance()
        boundaries.setText(trimmed)
        return trimmed.substring(0, boundaries.next()).uppercase()
    }

    /**
     * A stable palette slot per Mac: FNV-1a (32-bit) over the ID's UTF-8, mod
     * [paletteCount]. The Swift app computes the same.
     */
    fun colorIndex(macID: String, paletteCount: Int): Int {
        var hash = 2_166_136_261L
        for (byte in macID.toByteArray(Charsets.UTF_8)) {
            hash = ((hash xor (byte.toLong() and 0xFFL)) * 16_777_619L) and 0xFFFF_FFFFL
        }
        return (hash % paletteCount).toInt()
    }

    /**
     * Which Mac is selected after the paired list or credentials change: [current] while it is still
     * paired (with or without a shell credential); else [lastUsed] if paired; else the first paired
     * Mac with a shell, then the first paired Mac; null when none is paired.
     */
    fun selection(current: String?, lastUsed: String?, paired: List<String>, withShell: List<String>): String? = when {
        current != null && current in paired -> current
        lastUsed != null && lastUsed in paired -> lastUsed
        else -> withShell.firstOrNull { it in paired } ?: paired.firstOrNull()
    }

    /** The Mac to open on launch: the last used one if still paired, else the first. */
    fun reopen(lastUsed: String?, available: List<String>): String? =
        if (lastUsed != null && lastUsed in available) lastUsed else available.firstOrNull()

    /**
     * The Macs whose sessions to watch besides the selected one: every pinned
     * Mac, then up to [limit] of the rest, most recently used first (ties keep
     * candidate order). Pinned IDs count only when they are also in
     * [candidates]: those are the Macs with a usable shell credential, and a
     * Mac without one can't be dialed, so a stale pin is ignored.
     */
    fun watched(
        candidates: List<String>,
        selected: String?,
        recency: Map<String, Double>,
        pinned: Set<String>,
        limit: Int = 4,
    ): List<String> {
        val others = candidates.filter { it != selected }
        val pinnedFirst = others.filter { it in pinned }
        val rest = others.filter { it !in pinned }
            .sortedByDescending { recency[it] ?: 0.0 }
            .take(maxOf(limit, 0))
        return pinnedFirst + rest
    }

    /**
     * How recently each Mac was used, for [watched]: the later of when it
     * last answered and when it was last selected (Unix millis).
     */
    fun recency(lastHeard: Map<String, Long>, lastSelected: Map<String, Long>): Map<String, Double> =
        (lastHeard.keys + lastSelected.keys).associateWith { id ->
            maxOf(lastHeard[id] ?: Long.MIN_VALUE, lastSelected[id] ?: Long.MIN_VALUE).toDouble()
        }

    /** What [watchChanges] says to do: watches to end, then Macs to dial (in [wanted] order). */
    data class WatchChanges(val stop: Set<String>, val start: List<ShellCredential>)

    /**
     * Which watch connections to end and which to dial so the running set
     * becomes [wanted]: a Mac no longer wanted, or whose credential changed
     * (a new key or address), is stopped; a wanted Mac not running, or
     * stopped for a change, is started. `start` keeps [wanted]'s order.
     */
    fun watchChanges(running: Map<String, ShellCredential>, wanted: List<ShellCredential>): WatchChanges {
        val wantedByID = LinkedHashMap<String, ShellCredential>()
        for (credential in wanted) wantedByID.putIfAbsent(credential.macID, credential)
        val stop = running.filter { (id, credential) -> wantedByID[id] != credential }.keys
        val start = wanted.filter { running[it.macID] == null || it.macID in stop }
        return WatchChanges(stop, start)
    }
}

/** Production relative time: Android's localized phrase, e.g. "2 hours ago". */
private fun androidRelative(thenMillis: Long, nowMillis: Long): String =
    DateUtils.getRelativeTimeSpanString(thenMillis, nowMillis, DateUtils.MINUTE_IN_MILLIS).toString()
