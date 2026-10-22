package dev.dpatel.passthrough.core

/** Where secrets live apart from the pairing list: the Keystore-backed store in the app, a map in tests. */
interface SecretStore {
    fun read(account: String): ByteArray?
    /** False if the secret could not be stored. */
    fun write(account: String, data: ByteArray): Boolean
    fun delete(account: String)
}

class MemorySecrets : SecretStore {
    private val map = HashMap<String, ByteArray>()
    @Synchronized override fun read(account: String) = map[account]?.copyOf()
    @Synchronized override fun write(account: String, data: ByteArray): Boolean { map[account] = data.copyOf(); return true }
    @Synchronized override fun delete(account: String) { map.remove(account) }
}
