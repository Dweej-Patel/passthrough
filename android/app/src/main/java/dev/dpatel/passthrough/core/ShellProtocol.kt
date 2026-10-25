package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable
import java.net.InetAddress
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Shared pieces of the remote shell. Must match PassthroughCore/ShellProtocol.swift. */
object RemoteShell {
    const val DEFAULT_PORT = 7893
    const val SERVICE_TYPE = "_passthrough-sh._tcp"
    const val PROOF_LABEL = "passthrough-shell-v1"
    /** Most sessions a Mac keeps open at once. */
    const val MAX_SESSIONS = 8
    /** Output a session remembers for a phone that attaches later. */
    const val SCROLLBACK_BYTES = 1_048_576
    /** Largest piece of raw output (before base64) in one `output` line. */
    const val OUTPUT_CHUNK = 16_384
    /** Longest line either side accepts. */
    const val LINE_LIMIT = 262_144

    /** HMAC-SHA256(shellKey, label ‖ nonce): the phone's answer to the Mac's challenge. */
    fun proof(shellKey: ByteArray, nonce: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(shellKey, "HmacSHA256"))
            doFinal(PROOF_LABEL.toByteArray(Charsets.UTF_8) + nonce)
        }

    fun proofIsValid(mac: ByteArray, shellKey: ByteArray, nonce: ByteArray): Boolean =
        MessageDigest.isEqual(mac, proof(shellKey, nonce))
}

/**
 * Newline-delimited JSON envelope on the shell connection. Binary fields
 * (`data`, `nonce`, `mac`) are base64.
 */
@Serializable
data class ShellEnvelope(
    var t: String,
    var nonce: String? = null,
    var phoneID: String? = null,
    var mac: String? = null,
    var session: String? = null,
    var data: String? = null,
    var cols: Int? = null,
    var rows: Int? = null,
    var sessions: List<ShellSessionInfo>? = null,
    var history: List<ShellHistoryEntry>? = null,
    var exitStatus: Int? = null,
    var reason: String? = null,
    var done: Boolean? = null,
    /** macInfo: the Mac's iroh endpoint id, home relay, the relay's token and the addresses a phone can dial. */
    var irohID: String? = null,
    var irohRelay: String? = null,
    var relayToken: String? = null,
    var addresses: List<String>? = null,
    /** macState: how the Mac is doing, as this phone may see it. */
    var state: MacState? = null,
    /** setAwake / setVPN: what the phone asks for. */
    var on: Boolean? = null,
) {
    fun encodeLine(): ByteArray =
        (ControlEnvelope.json.encodeToString(serializer(), this) + "\n").toByteArray(Charsets.UTF_8)

    companion object {
        const val HELLO = "hello"
        const val MAC_INFO = "macInfo"
        const val CHALLENGE = "challenge"
        const val PROOF = "proof"
        const val READY = "ready"
        const val LIST = "list"
        const val SESSIONS = "sessions"
        const val OPEN = "open"
        const val OPENED = "opened"
        const val ATTACH = "attach"
        const val ATTACHED = "attached"
        const val INPUT = "input"
        const val RESIZE = "resize"
        const val OUTPUT = "output"
        const val CLOSE = "close"
        const val ENDED = "ended"
        const val DETACHED = "detached"
        const val HISTORY = "history"
        const val HISTORY_LIST = "historyList"
        const val TRANSCRIPT = "transcript"
        const val TRANSCRIPT_DATA = "transcriptData"
        /** The Mac's state ([MacState]), after `ready` and whenever it changes. */
        const val MAC_STATE = "macState"
        /** A phone turning Keep awake or the VPN on or off (`on`). */
        const val SET_AWAKE = "setAwake"
        const val SET_VPN = "setVPN"
        const val PING = "ping"
        const val PONG = "pong"
        const val ERROR = "error"

        fun decode(line: String): ShellEnvelope = ControlEnvelope.json.decodeFromString(serializer(), line)
    }
}

/** What a phone accepts as the Mac's iroh details (grant and `macInfo`). Mirrors IrohInfo in ShellProtocol.swift. */
object IrohInfo {
    const val MAX_RELAY_LENGTH = 256
    const val MAX_TOKEN_LENGTH = 512
    const val MAX_ADDRESSES = 16

    /** An iroh EndpointId: 64 lowercase hex characters. */
    fun isValidID(id: String): Boolean = id.length == 64 && id.all { it in '0'..'9' || it in 'a'..'f' }

    /** An https URL with a host, at most 256 characters. */
    fun isValidRelay(relay: String): Boolean {
        if (relay.toByteArray(Charsets.UTF_8).size > MAX_RELAY_LENGTH) return false
        val uri = runCatching { java.net.URI(relay) }.getOrNull() ?: return false
        return uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrEmpty()
    }

    fun isValidToken(token: String): Boolean = token.toByteArray(Charsets.UTF_8).size <= MAX_TOKEN_LENGTH

    /** Whether the iroh details form a usable group: a valid id, and a relay and token that are valid when present. */
    fun areValid(id: String?, relay: String?, token: String?): Boolean =
        id != null && isValidID(id) && (relay?.let(::isValidRelay) ?: true) && (token?.let(::isValidToken) ?: true)
}

/** A live shell session as the Mac lists it. Times are Unix seconds. */
@Serializable
data class ShellSessionInfo(
    val id: String,
    val title: String,
    val startedAt: Double,
    val lastOutputAt: Double,
    val running: Boolean,
    val exitStatus: Int? = null,
    /** The question a running session went quiet on, as the Mac reads its screen; absent when it isn't waiting. */
    val waiting: String? = null,
)

/** A past session in the Mac's history. Times are Unix seconds. */
@Serializable
data class ShellHistoryEntry(
    val id: String,
    val title: String,
    val phoneLabel: String,
    val startedAt: Double,
    val endedAt: Double? = null,
    val exitStatus: Int? = null,
    val bytes: Long,
    /** The terminal's size when the session started (absent from older Macs). */
    val cols: Int? = null,
    val rows: Int? = null,
)

/** Reasons the Mac gives in an `error` line. */
enum class ShellError(val wire: String) {
    NOT_AUTHORIZED("not_authorized"),
    TOO_MANY_SESSIONS("too_many_sessions"),
    NO_SUCH_SESSION("no_such_session"),
    BAD_REQUEST("bad_request"),
    /** The owner hasn't let this phone change Keep awake and the VPN. */
    NOT_ALLOWED("not_allowed"),
    /** The VPN can't turn on: the Mac has no VPN set up. */
    VPN_NOT_SET_UP("vpn_not_set_up"),
}

/**
 * How the Mac is doing, sent in `macState`. Every field is optional: a Mac
 * leaves out what it doesn't know or doesn't have. Mirrors MacState in ShellProtocol.swift.
 */
@Serializable
data class MacState(
    /** Keep awake is on. */
    val awake: Boolean? = null,
    /** Why Keep awake turned itself off or refused to turn on: `battery` or `heat`. */
    val awakeStopped: String? = null,
    /** 0 to 1; absent on a Mac without a battery. */
    val battery: Double? = null,
    /** On power, not the battery. */
    val charging: Boolean? = null,
    /** Minutes until Keep awake's battery limit, on battery, when macOS has an estimate. */
    val minutesLeft: Int? = null,
    /** The battery level (0 to 1) where Keep awake turns itself off; absent when that limit is off. */
    val batteryFloor: Double? = null,
    /** macOS says the Mac is running hot. */
    val hot: Boolean? = null,
    /** `off`, `connecting`, `on` or `failed`; absent when the Mac has no VPN set up. */
    val vpn: String? = null,
    /** The VPN profile in use, as the Mac names it. */
    val vpnName: String? = null,
    val killSwitch: Boolean? = null,
    /** This phone may change Keep awake and the VPN (`setAwake`, `setVPN`). */
    val control: Boolean? = null,
)

/**
 * Which peers may reach the shell, and which of the Mac's addresses a phone
 * is told about: private networks, loopback, link-local and Tailscale only.
 */
object ShellAddressPolicy {
    private enum class Kind { NONE, LOOPBACK, LINK_LOCAL, TAILSCALE, OTHER }

    private val ipv4Literal = Regex("""(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})""")
    private val ipv6Chars = Regex("""[0-9A-Fa-f:.]+""")
    private val tailscaleV6Prefix = intArrayOf(0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0)

    fun isAllowed(host: String): Boolean = classify(host) != Kind.NONE

    /** Allowed addresses worth dialing, deduplicated, with Tailscale last. */
    fun advertisable(addresses: List<String>): List<String> {
        val kept = addresses.filter { classify(it) == Kind.OTHER || classify(it) == Kind.TAILSCALE }.distinct()
        return kept.filter { classify(it) == Kind.OTHER } + kept.filter { classify(it) == Kind.TAILSCALE }
    }

    private fun classify(host: String): Kind {
        val bare = host.substringBefore('%')
        ipv4Literal.matchEntire(bare)?.let { m ->
            val b = m.groupValues.drop(1).map { it.toInt() }
            if (b.any { it > 255 }) return Kind.NONE
            return when {
                b[0] == 127 -> Kind.LOOPBACK
                b[0] == 169 && b[1] == 254 -> Kind.LINK_LOCAL
                b[0] == 100 && b[1] in 64..127 -> Kind.TAILSCALE
                b[0] == 10 || (b[0] == 192 && b[1] == 168) -> Kind.OTHER
                b[0] == 172 && b[1] in 16..31 -> Kind.OTHER
                else -> Kind.NONE
            }
        }
        // Only literals reach InetAddress, so this never touches DNS.
        if (!ipv6Chars.matches(bare) || ':' !in bare) return Kind.NONE
        val b = try { InetAddress.getByName(bare).address } catch (_: Exception) { return Kind.NONE }
        if (b.size != 16) return Kind.NONE
        val u = b.map { it.toInt() and 0xFF }
        return when {
            u.take(15).all { it == 0 } && u[15] == 1 -> Kind.LOOPBACK
            u[0] == 0xFE && u[1] and 0xC0 == 0x80 -> Kind.LINK_LOCAL
            u.take(6) == tailscaleV6Prefix.toList() -> Kind.TAILSCALE
            u[0] and 0xFE == 0xFC -> Kind.OTHER
            else -> Kind.NONE
        }
    }
}
