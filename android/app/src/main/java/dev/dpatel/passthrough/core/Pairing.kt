package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale

/** Minimal persistence the registry needs; SharedPreferences in the app, a map in tests. */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

class MemoryStore : KeyValueStore {
    private val map = HashMap<String, String>()
    @Synchronized override fun getString(key: String) = map[key]
    @Synchronized override fun putString(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
}

/**
 * The secret a phone issues each Mac it pairs with: 32 random bytes as
 * unpadded URL-safe base64. The phone keeps only its SHA-256. Mirrors
 * PairingToken in PassthroughCore/Pairing.swift.
 */
object PairingToken {
    const val LENGTH = 43
    private val random = SecureRandom()

    fun generate(): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** Lowercase hex SHA-256, the form the phone stores. */
    fun hash(token: String): String =
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    /** Whether [token] has the shape [generate] produces. */
    fun isWellFormed(token: String): Boolean =
        token.length == LENGTH && token.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }
}

/** A Mac that has been granted access to this phone's proxy. Times are epoch millis. */
@Serializable
data class PairedClient(
    val id: String,
    val name: String,
    val tokenHash: String,
    val pairedAt: Long,
    val lastSeen: Long? = null,
)

/**
 * Stores paired Macs and the short-lived pairing code. Mirrors
 * PassthroughCore/Pairing.swift: six digit codes valid for five minutes,
 * withdrawn after five wrong guesses, and a 32-byte URL-safe token per Mac of
 * which only the SHA-256 is kept.
 */
class PairingRegistry(
    private val store: KeyValueStore,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class Code(val code: String, val expiry: Long)

    sealed interface PairResult {
        data class Success(val token: String) : PairResult
        data class Failure(val reason: PairingFailure) : PairResult
    }

    private val lock = Any()
    private val random = SecureRandom()
    private var code: Code? = null
    private var failedAttempts = 0
    @Volatile var onChange: (() -> Unit)? = null

    val clients: List<PairedClient> get() = synchronized(lock) { loadClients() }

    private fun loadClients(): List<PairedClient> {
        val raw = store.getString(CLIENTS_KEY) ?: return emptyList()
        return runCatching { ControlEnvelope.json.decodeFromString(ListSerializer(PairedClient.serializer()), raw) }.getOrDefault(emptyList())
    }

    private fun save(list: List<PairedClient>) {
        store.putString(CLIENTS_KEY, ControlEnvelope.json.encodeToString(ListSerializer(PairedClient.serializer()), list))
    }

    // Pairing code

    fun issueCode(): Code {
        val c = Code(String.format(Locale.US, "%06d", random.nextInt(1_000_000)), clock() + PassthroughProtocol.PAIRING_CODE_LIFETIME_MS)
        synchronized(lock) { code = c; failedAttempts = 0 }
        onChange?.invoke()
        return c
    }

    fun clearCode() {
        synchronized(lock) { code = null }
        onChange?.invoke()
    }

    val activeCode: Code? get() = synchronized(lock) { code?.takeIf { it.expiry > clock() } }

    /** Validates a code and registers the Mac; returns the token to hand back. */
    fun pair(code: String, clientID: String, name: String): PairResult {
        val result: PairResult = synchronized(lock) {
            val stored = this.code ?: return@synchronized PairResult.Failure(PairingFailure.EXPIRED)
            if (stored.expiry <= clock()) {
                this.code = null
                return@synchronized PairResult.Failure(PairingFailure.EXPIRED)
            }
            if (!constantTimeEquals(stored.code, code.trim())) {
                // A six-digit code must not be brute-forceable over the cable:
                // a handful of wrong guesses burns it; the user shows a new one.
                failedAttempts++
                if (failedAttempts >= MAX_ATTEMPTS) {
                    ptLog(PtLog.Level.WARNING, "Pairing code withdrawn after $failedAttempts wrong attempts")
                    this.code = null
                    return@synchronized PairResult.Failure(PairingFailure.EXPIRED)
                }
                return@synchronized PairResult.Failure(PairingFailure.BAD_CODE)
            }
            if (clientID.length > 64 || name.length > 64 || clientID.isEmpty()) return@synchronized PairResult.Failure(PairingFailure.BAD_CODE)
            val token = PairingToken.generate()
            val now = clock()
            save(loadClients().filter { it.id != clientID } + PairedClient(clientID, name, PairingToken.hash(token), now, now))
            this.code = null
            PairResult.Success(token)
        }
        if (result is PairResult.Success) ptLog(PtLog.Level.INFO, "Paired Mac $name")
        onChange?.invoke()
        return result
    }

    fun verify(clientID: String, token: String): Boolean = synchronized(lock) {
        val client = loadClients().firstOrNull { it.id == clientID } ?: return false
        constantTimeEquals(client.tokenHash, PairingToken.hash(token))
    }

    fun touch(clientID: String) {
        synchronized(lock) {
            val list = loadClients()
            if (list.none { it.id == clientID }) return
            save(list.map { if (it.id == clientID) it.copy(lastSeen = clock()) else it })
        }
        onChange?.invoke()
    }

    fun revoke(clientID: String) {
        synchronized(lock) { save(loadClients().filter { it.id != clientID }) }
        onChange?.invoke()
    }

    fun revokeAll() {
        synchronized(lock) { save(emptyList()) }
        onChange?.invoke()
    }

    companion object {
        const val CLIENTS_KEY = "pairing.clients"
        private const val MAX_ATTEMPTS = 5
        private fun constantTimeEquals(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }
}
