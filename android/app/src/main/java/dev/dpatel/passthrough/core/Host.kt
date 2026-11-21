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

        internal fun isLine(text: String?, max: Int): Boolean =
            text != null && text.isNotEmpty() && text.length <= max && text.none { it.isISOControl() }
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

/** What the device on this connection may do on the host ([HostInfo.access]). */
@Serializable
data class HostAccess(
    val shell: Boolean? = null,
    val screen: Boolean? = null,
    /** May hand access to this host on to another computer. */
    val share: Boolean? = null,
)
