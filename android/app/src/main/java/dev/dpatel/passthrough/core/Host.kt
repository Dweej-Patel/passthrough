package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable

/**
 * What a host says about itself in `host`, sent right after `ready` (after
 * `macInfo`) and again whenever it changes (protocol/README.md, "The host").
 * Every field is optional; a host that sends no `host` is a Mac from before it.
 * Mirrors HostInfo in Host.swift.
 */
@Serializable
data class HostInfo(
    /** `mac` or `windows`; an unknown kind is kept and treated as neither. */
    val kind: String? = null,
    val os: String? = null,
    /** The account that granted this phone has a session on the host (locked counts). */
    val signedIn: Boolean? = null,
    /** Passthrough is running in that session, so shells can start. */
    val app: Boolean? = null,
    /** `active`, `locked`, `signedOut` or `otherUser`; absent when unknown. */
    val console: String? = null,
    val idleSeconds: Int? = null,
    val shells: List<HostShell>? = null,
    /** Any of `video`, `rfb`, `rdp`. */
    val screens: List<String>? = null,
    /** `ready`, or why not: `off`, `edition`, `account`, `service`, `exposed`, `policy`. */
    val rdp: String? = null,
    val access: HostAccess? = null,
    /** This device may lock the host's screen. */
    val lock: Boolean? = null,
    val idKey: String? = null,
    /** The name its Windows sign-in takes; sent only to a device allowed the screen. */
    val user: String? = null,
    /** Seconds on mains until the host sleeps; 0 for never. */
    val sleepAfter: Int? = null,
    /** The host's own monitor, so a viewer can leave its size and scale as they are. */
    val display: HostDisplay? = null,
) {
    /**
     * What the app may rely on: null without a [kind]; malformed fields dropped,
     * shells checked, at most one default, unknown [console] values dropped.
     */
    fun cleaned(): HostInfo? {
        if (!isLine(kind, 32)) return null
        val shells = shells?.let { list ->
            val seen = HashSet<String>()
            var hasDefault = false
            list.filter { HostShell.isValidID(it.id) && isLine(it.name, 64) && seen.add(it.id) }
                .take(MAX_SHELLS)
                .map { shell ->
                    if (shell.default == true) {
                        if (hasDefault) shell.copy(default = null) else shell.also { hasDefault = true }
                    } else shell
                }
        }
        return copy(
            os = os.takeIf { isLine(it, 64) },
            console = console.takeIf { it in CONSOLE_STATES },
            idleSeconds = idleSeconds?.takeIf { it >= 0 },
            sleepAfter = sleepAfter?.takeIf { it >= 0 },
            display = display?.takeIf { it.width in 1..16_384 && it.height in 1..16_384 && it.scale in 100..500 },
            rdp = rdp.takeIf { isLine(it, 32) },
            user = user.takeIf { isLine(it, 256) },
            idKey = idKey?.takeIf { k -> k.length <= 512 && k.all { it in '0'..'9' || it in 'a'..'f' } },
            screens = screens?.filter { isLine(it, 16) }?.take(8),
            shells = shells,
        )
    }

    companion object {
        const val KIND_MAC = "mac"
        const val KIND_WINDOWS = "windows"
        const val MAX_SHELLS = 32
        const val MAX_LINE_BYTES = 16_384
        const val IN_USE_IDLE_SECONDS = 120
        val CONSOLE_STATES = listOf("active", "locked", "signedOut", "otherUser")
        val GOING_AWAY_REASONS = listOf("sleeping", "turned_off", "shutting_down")

        /** 1 to [max] UTF-16 units, with no control, format (bidi, zero-width) or line/paragraph separator characters. */
        internal fun isLine(text: String?, max: Int): Boolean =
            text != null && text.isNotEmpty() && text.length <= max && text.none {
                it.isISOControl() || Character.getType(it).toByte().let { t ->
                    t == Character.FORMAT || t == Character.LINE_SEPARATOR || t == Character.PARAGRAPH_SEPARATOR
                }
            }
    }
}

/** A shell a host offers ([HostInfo.shells]). */
@Serializable
data class HostShell(
    /** Stable id, sent back in `open`'s `shell`: `pwsh`, `cmd`, `wsl:Ubuntu`, a Mac's `login`. */
    val id: String,
    val name: String,
    /** The one a plain `open` starts. */
    val default: Boolean? = null,
) {
    companion object {
        const val LOGIN_ID = "login"

        /** 1 to 80 characters: a letter or digit, then letters, digits, `:`, `.`, `_` or `-`. */
        fun isValidID(id: String): Boolean {
            if (id.length !in 1..80 || !alnum(id[0])) return false
            return id.all { alnum(it) || it == ':' || it == '.' || it == '_' || it == '-' }
        }

        private fun alnum(c: Char) = c in '0'..'9' || c in 'A'..'Z' || c in 'a'..'z'
    }
}

/** The host's own monitor ([HostInfo.display]): pixels, and its scale in percent. */
@Serializable
data class HostDisplay(val width: Int, val height: Int, val scale: Int)

/** What the device on this connection may do on the host ([HostInfo.access]). */
@Serializable
data class HostAccess(
    val shell: Boolean? = null,
    val screen: Boolean? = null,
    /** May hand access to this host on to another computer. */
    val share: Boolean? = null,
)

/** What kind of computer a host is. [wire] is the protocol's word. Mirrors HostKind in Host.swift. */
enum class HostKind(val wire: String) {
    MAC(HostInfo.KIND_MAC),
    WINDOWS(HostInfo.KIND_WINDOWS);

    companion object {
        /** Null for anything this build doesn't know (and for none). */
        fun fromWire(wire: String?): HostKind? = entries.firstOrNull { it.wire == wire }
    }
}

/** Mirrors Hosts in Host.swift. */
object Hosts {
    /**
     * The kind words and rows are chosen by: what the live (or last stored) `host` says, then
     * what the pairing or grant recorded ([PairedClient.hostKind]), then a Mac, since a computer
     * that never said is one from before Windows hosts. Null only when a `host` named a kind this
     * build doesn't know: neutral words, and only shells.
     */
    fun kind(live: HostInfo?, stored: String?): HostKind? {
        live?.kind?.let { return HostKind.fromWire(it) }
        return HostKind.fromWire(stored) ?: HostKind.MAC
    }

    /**
     * The shell a plain New shell opens: the one [lastChosen] names if [host] still lists it,
     * else the host's default, else its first. Null when the host lists none.
     */
    fun preferredShell(host: HostInfo?, lastChosen: String?): HostShell? {
        val shells = host?.shells.orEmpty()
        return shells.firstOrNull { it.id == lastChosen } ?: shells.firstOrNull { it.default == true } ?: shells.firstOrNull()
    }

    /** Whether New shell offers a choice (and `open` names a shell): the host lists more than one. */
    fun offersChoice(host: HostInfo?): Boolean = (host?.shells?.size ?: 0) > 1
}

/**
 * Why a host said it was leaving (one of [HostInfo.GOING_AWAY_REASONS], or one this build
 * doesn't know, shown as "can't reach"), and when this phone heard it (Unix millis).
 */
@Serializable
data class HostFarewell(val reason: String, val atMillis: Long) {
    companion object {
        const val SLEEPING = "sleeping"
        const val TURNED_OFF = "turned_off"
        const val SHUTTING_DOWN = "shutting_down"
    }
}
