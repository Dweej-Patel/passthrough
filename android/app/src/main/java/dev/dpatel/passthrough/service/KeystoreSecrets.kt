package dev.dpatel.passthrough.service

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.SecretStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secrets encrypted with an AES-256-GCM key that never leaves the Android
 * Keystore; IV and ciphertext are kept as base64 in private preferences.
 */
class KeystoreSecrets(context: Context) : SecretStore {
    private val prefs = context.getSharedPreferences("secrets", Context.MODE_PRIVATE)

    /** Synchronized: two first uses at once (a grant on the control thread, a read in the app) must not make two keys. */
    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).apply { init(spec) }.generateKey()
    }

    override fun read(account: String): ByteArray? {
        val raw = prefs.getString(account, null) ?: return null
        return try {
            val blob = Base64.decode(raw, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_SIZE))
            cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE)
        } catch (e: Exception) {
            PtLog.log(PtLog.Level.ERROR, "Could not read secret $account: ${e.javaClass.simpleName}")
            null
        }
    }

    @android.annotation.SuppressLint("ApplySharedPref")
    override fun write(account: String, data: ByteArray): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val blob = cipher.iv + cipher.doFinal(data)
        prefs.edit().putString(account, Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
    } catch (e: Exception) {
        PtLog.log(PtLog.Level.ERROR, "Could not store secret $account: ${e.javaClass.simpleName}")
        false
    }

    @android.annotation.SuppressLint("ApplySharedPref")
    override fun delete(account: String) { prefs.edit().remove(account).commit() }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "passthrough.secrets"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}
