package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Constants shared with the Mac client. Must match PassthroughCore/Protocol.swift. */
object PassthroughProtocol {
    /** Bump when the wire protocol changes incompatibly. */
    const val VERSION = 1
    /** SOCKS5 port the phone listens on (loopback only, reached over adb). */
    const val DEFAULT_SOCKS_PORT = 7890
    /** Control channel port (pairing, heartbeat, device status). */
    const val DEFAULT_CONTROL_PORT = 7891
    const val PAIRING_CODE_LIFETIME_MS = 300_000L
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
    var token: String? = null,
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
) {
    fun encodeLine(): ByteArray = (json.encodeToString(serializer(), this) + "\n").toByteArray(Charsets.UTF_8)

    companion object {
        const val HELLO = "hello"
        const val WELCOME = "welcome"
        const val PAIR = "pair"
        const val PAIRED = "paired"
        const val ERROR = "error"
        const val PING = "ping"
        const val PONG = "pong"
        const val STATUS = "status"

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
