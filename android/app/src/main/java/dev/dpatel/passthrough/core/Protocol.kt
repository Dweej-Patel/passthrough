package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Constants shared with the Mac client. Must match PassthroughCore/Protocol.swift. */
object PassthroughProtocol {
    /** Bump when the wire protocol changes incompatibly. 2: the pairing is proved with HMACs ([ControlAuth]), never by sending the token. */
    const val VERSION = 2
    /** SOCKS5 port the phone listens on (loopback only, reached over adb). */
    const val DEFAULT_SOCKS_PORT = 7890
    /** Control channel port (pairing, heartbeat, device status). */
    const val DEFAULT_CONTROL_PORT = 7891
    const val PAIRING_CODE_LIFETIME_MS = 300_000L
    /** Wrong codes one control connection may send: the last of them is answered `locked` and the connection is closed. */
    const val PAIRING_MAX_WRONG_CODES_PER_CONNECTION = 3
    /**
     * Wrong codes one pairing code takes, over every connection, before the phone
     * withdraws it (`code_withdrawn`) and a new one must be shown: a guesser wins
     * with odds of at most 10 in a million per code shown, and nothing can hold the
     * right code off (see [PairingRegistry.pair]).
     */
    const val PAIRING_MAX_WRONG_CODES_PER_CODE = 10
    /** A control connection that has not proved a pairing is closed after this, unless a pairing code is showing. */
    const val UNAUTHENTICATED_TIMEOUT_MS = 10_000L
    /** An authenticated Mac silent this long is dropped (it pings every 5 s and gives up itself after 20 s). */
    const val SILENCE_LIMIT_MS = 30_000L
}

/**
 * Newline-delimited JSON envelope used on the control channel. Every message
 * carries a type tag `t`; the remaining fields are optional and omitted when null,
 * exactly like Swift's JSONEncoder does for the Mac side.
 */
@Serializable
data class ControlEnvelope(
    var t: String,
    var protocolVersion: Int? = null,
    var clientID: String? = null,
    var name: String? = null,
    var code: String? = null,
    /** paired: the new pairing token. Never sent anywhere else. */
    var token: String? = null,
    /** hello, welcome: 32 random bytes, base64, fresh for every connection. */
    var nonce: String? = null,
    /** welcome (the phone's) and auth (the Mac's): the HMAC proving the pairing, base64 (see [ControlAuth]). */
    var proof: String? = null,
    var reason: String? = null,
    var paired: Boolean? = null,
    var socksPort: Int? = null,
    var deviceName: String? = null,
    var radio: String? = null,
    var carrier: String? = null,
    var battery: Double? = null,
    var hosting: String? = null,
    /** Whether the phone's current network routes IPv6. Absent from older phones. */
    var ipv6: Boolean? = null,
    var activeConnections: Int? = null,
    var rxBytes: Long? = null,
    var txBytes: Long? = null,
    var timestamp: Double? = null,
    /** hello: how the Mac reaches the phone, "usb" or "wireless" (always the cable for Android). */
    var via: String? = null,
    // Granting remote shell access (protocol/README.md, "Remote shell").
    var certSHA256: String? = null,
    var phoneID: String? = null,
    var shellKey: String? = null,
    var shellPort: Int? = null,
    /** shellGrant: addresses a phone can dial the Mac's shell listener on. */
    var addresses: List<String>? = null,
    var macName: String? = null,
    /** shellGrant: the Mac's iroh endpoint id, home relay URL and the relay's token. */
    var irohID: String? = null,
    var irohRelay: String? = null,
    var relayToken: String? = null,
    /** shellGrant: names this grant (at most 64 UTF-8 bytes); the phone echoes it in shellGranted. */
    var grantID: String? = null,
) {
    fun encodeLine(): ByteArray = (json.encodeToString(serializer(), this) + "\n").toByteArray(Charsets.UTF_8)

    companion object {
        const val HELLO = "hello"
        const val WELCOME = "welcome"
        const val AUTH = "auth"
        const val PAIR = "pair"
        const val PAIRED = "paired"
        const val ERROR = "error"
        const val PING = "ping"
        const val PONG = "pong"
        const val STATUS = "status"
        const val SHELL_GRANT = "shellGrant"
        const val SHELL_GRANTED = "shellGranted"
        /** The longest grantID (UTF-8 bytes) a phone echoes. */
        const val MAX_GRANT_ID_LENGTH = 64

        internal val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            encodeDefaults = false
        }

        fun decode(line: String): ControlEnvelope = json.decodeFromString(serializer(), line)
    }
}

/** Reasons a pairing attempt can fail, sent back over the control channel. */
enum class PairingFailure(val wire: String) {
    BAD_CODE("bad_code"),
    EXPIRED("expired"),
    NOT_AUTHENTICATED("not_authenticated"),
    UNSUPPORTED_VERSION("unsupported_version"),
    /** Too many wrong codes on this connection: the phone closes it. The code still stands for a new connection, unless it was withdrawn. */
    LOCKED("locked"),
    /** Too many wrong codes against this code in all: the phone withdrew it, and pairing needs a new one shown. */
    CODE_WITHDRAWN("code_withdrawn"),
}

/** Facts about the phone the Mac likes to display. */
data class DeviceStatus(
    val deviceName: String,
    val radio: String? = null,
    val carrier: String? = null,
    val battery: Double? = null,
    val hosting: String,
    /** Whether the network the phone sends Mac traffic out on routes IPv6; null when unknown. */
    val ipv6: Boolean? = null,
)

/** A connected Mac as seen by the phone. */
data class ConnectedMac(val id: String, val name: String, val since: Long)
