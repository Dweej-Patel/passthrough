package dev.dpatel.passthrough.core

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The format of the shell key vault (service/ShellKeyVault.kt) on Android 11
 * and later: every Mac's key in one blob, so the app's single unlock prompt
 * opens them all. The vault's Keystore key, which needs an authentication for
 * every use, wraps a random data key; the data key seals the blob. Pure
 * (javax.crypto in software), so it is testable without a Keystore.
 *
 * - wrapped data key: `[iv 12][AES-GCM(data key 32) + tag]`, by the Keystore key
 * - sealed blob: `[iv 12][AES-GCM(payload) + tag]`, by the data key, with [AAD]
 * - payload: `[version 1][count u16]`, then per Mac `[id length u16][id UTF-8][key length u16][key]`
 */
object ShellVaultBlob {
    const val VERSION = 1
    const val DATA_KEY_SIZE = 32
    const val IV_SIZE = 12
    private const val TAG_BITS = 128
    private const val TRANSFORM = "AES/GCM/NoPadding"
    /** Binds the sealed blob to this use: it can't pass for anything else sealed with the same key. */
    private val AAD = "passthrough.shell.vault.$VERSION".toByteArray()

    fun newDataKey(random: SecureRandom = SecureRandom()): ByteArray = ByteArray(DATA_KEY_SIZE).also(random::nextBytes)

    fun encode(keys: Map<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use { d ->
            d.writeByte(VERSION)
            d.writeShort(keys.size)
            for ((id, key) in keys.toSortedMap()) {
                val name = id.toByteArray(Charsets.UTF_8)
                require(name.size <= 0xFFFF && key.size <= 0xFFFF && keys.size <= 0xFFFF)
                d.writeShort(name.size); d.write(name)
                d.writeShort(key.size); d.write(key)
            }
        }
        return out.toByteArray()
    }

    /** Null when [payload] isn't a whole, well-formed payload of this version. */
    fun decode(payload: ByteArray): Map<String, ByteArray>? = try {
        DataInputStream(payload.inputStream()).use { d ->
            if (d.readUnsignedByte() != VERSION) return null
            val count = d.readUnsignedShort()
            val keys = LinkedHashMap<String, ByteArray>(count)
            repeat(count) {
                val id = ByteArray(d.readUnsignedShort()).also(d::readFully).toString(Charsets.UTF_8)
                val key = ByteArray(d.readUnsignedShort()).also(d::readFully)
                if (id.isEmpty() || id in keys) return null
                keys[id] = key
            }
            if (d.read() != -1) return null   // trailing bytes: not what was written
            keys
        }
    } catch (_: IOException) {
        null
    }

    fun seal(dataKey: ByteArray, keys: Map<String, ByteArray>, random: SecureRandom = SecureRandom()): ByteArray {
        val iv = ByteArray(IV_SIZE).also(random::nextBytes)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(dataKey, "AES"), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(AAD)
        return iv + cipher.doFinal(encode(keys))
    }

    /** Null when [sealed] wasn't sealed with [dataKey] (or was altered) or doesn't decode. */
    fun open(dataKey: ByteArray, sealed: ByteArray): Map<String, ByteArray>? {
        if (sealed.size < IV_SIZE + TAG_BITS / 8) return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(dataKey, "AES"), GCMParameterSpec(TAG_BITS, sealed, 0, IV_SIZE))
            cipher.updateAAD(AAD)
            decode(cipher.doFinal(sealed, IV_SIZE, sealed.size - IV_SIZE))
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    // Migration from the per-Mac entries of the older vault

    /** What reading one of the older vault's per-Mac entries gave. */
    sealed interface LegacyRead {
        class Key(val bytes: ByteArray) : LegacyRead
        /** Its Keystore key was invalidated (lock screen removed): that Mac's key is lost. */
        data object Invalidated : LegacyRead
        /** Not now (no recent authentication, a Keystore hiccup): keep the entry for the next unlock. */
        data object Retry : LegacyRead
    }

    /**
     * [keys]: what the blob will hold. [lost]: Macs whose older entries can
     * never be read. [migrated]: older entries done with (moved, superseded or
     * lost), to delete once [keys] is written. Entries not in [migrated] stay.
     */
    class Migration(val keys: Map<String, ByteArray>, val lost: Set<String>, val migrated: Set<String>)

    /**
     * Folds the older vault's entries into [current]. A key already in the
     * blob is newer (a grant adopted since) and wins over the older entry.
     */
    fun migrate(current: Map<String, ByteArray>, legacy: Map<String, LegacyRead>): Migration {
        val keys = LinkedHashMap(current)
        val lost = HashSet<String>()
        val migrated = HashSet<String>()
        for ((id, read) in legacy) {
            when {
                id in current -> migrated += id
                read is LegacyRead.Key -> { keys[id] = read.bytes; migrated += id }
                read == LegacyRead.Invalidated -> { lost += id; migrated += id }
                else -> Unit
            }
        }
        return Migration(keys, lost, migrated)
    }
}
