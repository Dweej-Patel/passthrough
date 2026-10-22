package dev.dpatel.passthrough.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Locale
import java.util.UUID

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

/**
 * Where a Mac's shell listener is and which certificate it presents. The key
 * itself is kept apart, in the secret store.
 */
@Serializable
data class ShellGrant(
    val certSHA256: String,
    val port: Int,
    val addresses: List<String>,
    val macName: String,
    /** The Mac's iroh endpoint id and home relay, when it offers the shell over iroh. The relay's token is kept in the secret store. */
    val irohID: String? = null,
    val irohRelay: String? = null,
)

/** A Mac that has been granted access to this phone's proxy. Times are epoch millis. */
@Serializable
data class PairedClient(
    val id: String,
    val name: String,
    val tokenHash: String,
    val pairedAt: Long,
    val lastSeen: Long? = null,
    /** How to reach this Mac's shell listener, once it granted a shell key over the cable. */
    val shell: ShellGrant? = null,
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
    private val secrets: SecretStore = MemorySecrets(),
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

    /** This phone's identity towards Macs with a shell grant: random, created once. */
    val phoneID: String get() = synchronized(lock) {
        store.getString(PHONE_ID_KEY) ?: UUID.randomUUID().toString().also { store.putString(PHONE_ID_KEY, it) }
    }

    /**
     * Records the shell key a paired Mac sent over the cable. The key waits in
     * the secret store until the app moves it elsewhere. False if the Mac isn't
     * paired or the key could not be stored; nothing is recorded then.
     */
    fun grantShell(clientID: String, grant: ShellGrant, shellKey: ByteArray, relayToken: String? = null): Boolean {
        val stored = synchronized(lock) {
            val list = loadClients()
            if (list.none { it.id == clientID } || !secrets.write(PENDING_SHELL + clientID, shellKey) ||
                !storeRelayToken(clientID, relayToken)) return@synchronized false
            save(list.map { if (it.id == clientID) it.copy(shell = grant) else it })
            true
        }
        if (stored) onChange?.invoke()
        return stored
    }

    /**
     * Applies a `macInfo` from a Mac this phone has a shell grant for. Valid
     * addresses (capped at 16) always apply. The iroh details apply as a group
     * only when valid: a valid id sets them (an absent token clears the stored
     * one), an absent id clears them and the token (the Mac is the source of
     * truth), invalid details leave the stored ones alone. Never touches the
     * shell key or certificate. False if there is no grant.
     */
    fun updateShellInfo(clientID: String, irohID: String?, irohRelay: String?, relayToken: String?, addresses: List<String>?): Boolean {
        val stored = synchronized(lock) {
            val list = loadClients()
            var grant = list.firstOrNull { it.id == clientID }?.shell ?: return@synchronized false
            if (addresses != null) grant = grant.copy(addresses = addresses.take(IrohInfo.MAX_ADDRESSES))
            if (irohID == null) {
                if (storeRelayToken(clientID, null)) grant = grant.copy(irohID = null, irohRelay = null)
            } else if (IrohInfo.areValid(irohID, irohRelay, relayToken) && storeRelayToken(clientID, relayToken)) {
                grant = grant.copy(irohID = irohID, irohRelay = irohRelay)
            }
            val updated = grant
            save(list.map { if (it.id == clientID) it.copy(shell = updated) else it })
            true
        }
        if (stored) onChange?.invoke()
        return stored
    }

    /** The relay token a Mac's grant or `macInfo` carried. */
    fun relayToken(clientID: String): String? = secrets.read(RELAY_TOKEN + clientID)?.toString(Charsets.UTF_8)

    private fun storeRelayToken(clientID: String, token: String?): Boolean {
        if (token.isNullOrEmpty()) { secrets.delete(RELAY_TOKEN + clientID); return true }
        return secrets.write(RELAY_TOKEN + clientID, token.toByteArray(Charsets.UTF_8))
    }

    fun pendingShellKey(clientID: String): ByteArray? = secrets.read(PENDING_SHELL + clientID)

    fun clearPendingShellKey(clientID: String) = secrets.delete(PENDING_SHELL + clientID)

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
        synchronized(lock) {
            secrets.delete(PENDING_SHELL + clientID)
            secrets.delete(RELAY_TOKEN + clientID)
            save(loadClients().filter { it.id != clientID })
        }
        onChange?.invoke()
    }

    fun revokeAll() {
        synchronized(lock) {
            loadClients().forEach { secrets.delete(PENDING_SHELL + it.id); secrets.delete(RELAY_TOKEN + it.id) }
            save(emptyList())
        }
        onChange?.invoke()
    }

    companion object {
        const val CLIENTS_KEY = "pairing.clients"
        const val PHONE_ID_KEY = "pairing.phoneID"
        private const val PENDING_SHELL = "shell.pending."
        private const val RELAY_TOKEN = "shell.relayToken."
        private const val MAX_ATTEMPTS = 5
        private fun constantTimeEquals(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }
}
