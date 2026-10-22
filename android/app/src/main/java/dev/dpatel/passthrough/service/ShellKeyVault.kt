package dev.dpatel.passthrough.service

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import dev.dpatel.passthrough.core.PairingRegistry
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ShellKeyStatus
import dev.dpatel.passthrough.core.ShellLostKeys
import dev.dpatel.passthrough.core.ptLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The app's private home for remote-shell keys. A key a Mac grants over the
 * cable waits as "pending" in the registry's secret store; right after each
 * app unlock [adoptPending] moves it here: encrypted with a Keystore AES-GCM
 * key that needs the user to have authenticated (strong biometric or device
 * credential) within the last 60 seconds. Android invalidates it when the
 * lock screen is removed; enrolling another face or fingerprint does not
 * (with an authentication window the key is bound to the user's root SID,
 * not to the enrolled biometrics). The vault never
 * prompts; when the window has passed it reports [ShellKeyStatus.LOCKED] and
 * the app lock prompts on the next foreground. Mirrors iOS/App/Shell/ShellKeyVault.swift.
 *
 * Blocking (Keystore and disk): call off the main thread. Keys are never logged.
 */
// commit(): a key must be on disk before its pending copy is cleared; never called on the main thread.
@android.annotation.SuppressLint("ApplySharedPref")
class ShellKeyVault(context: Context) {
    sealed interface Read {
        class Key(val bytes: ByteArray) : Read
        data object Missing : Read
        /** Reading would need a fresh unlock. */
        data object Locked : Read
        /** The vault's key was invalidated; every entry is gone. */
        data object Unavailable : Read
    }

    private enum class Stored { OK, LOCKED, INVALIDATED, FAILED }

    private val keyguard = context.getSystemService(KeyguardManager::class.java)
    private val prefs = context.applicationContext.getSharedPreferences("shell_vault", Context.MODE_PRIVATE)
    private val _status = MutableStateFlow(baseStatus())
    val status: StateFlow<ShellKeyStatus> = _status.asStateFlow()

    /** Remote shell needs API 29+ (TLS 1.3). */
    val supported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** False when the device has no secure lock screen: the vault can't hold keys then. */
    val deviceSecure: Boolean get() = keyguard?.isDeviceSecure == true

    /**
     * Moves every pending key into the vault and clears it from the pending
     * store. Without a secure lock screen nothing moves (keys stay pending).
     * Returns how many moved.
     */
    @Synchronized
    fun adoptPending(registry: PairingRegistry): Int {
        if (!supported || !deviceSecure) return 0.also { _status.value = baseStatus() }
        migrateLegacyLost(registry)
        var moved = 0
        for (client in registry.clients) {
            if (client.shell == null) continue
            val key = registry.pendingShellKey(client.id) ?: continue
            var result = store(client.id, key)
            if (result == Stored.INVALIDATED) {
                wipe()
                result = store(client.id, key)
            }
            when (result) {
                Stored.OK -> {
                    // A newer grant may have landed meanwhile: leave that one for the next unlock.
                    if (registry.pendingShellKey(client.id)?.contentEquals(key) == true) registry.clearPendingShellKey(client.id)
                    // Only this Mac's loss is over: others' keys stay lost until they grant again.
                    setLost(ShellLostKeys.afterAdopt(lost(), client.id))
                    moved++
                }
                Stored.LOCKED -> {
                    _status.value = ShellKeyStatus.LOCKED
                    return moved
                }
                Stored.INVALIDATED, Stored.FAILED -> Unit
            }
        }
        _status.value = baseStatus()
        if (moved > 0) ptLog(PtLog.Level.INFO, "shell: adopted $moved key(s)")
        return moved
    }

    /** Whether [macID]'s key was lost when the vault's key was invalidated (until that Mac grants again). */
    @Synchronized
    fun isLost(macID: String): Boolean = macID in lost()

    /** The key for [macID], or null (missing, locked or lost: see [status]). */
    fun key(macID: String): ByteArray? = (read(macID) as? Read.Key)?.bytes

    @Synchronized
    fun read(macID: String): Read {
        if (!supported) return Read.Missing
        if (!deviceSecure) {
            _status.value = ShellKeyStatus.NEEDS_PASSCODE
            return Read.Missing
        }
        val raw = prefs.getString(entry(macID), null) ?: return Read.Missing
        return try {
            val blob = Base64.decode(raw, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, existingKey() ?: return Read.Missing, GCMParameterSpec(128, blob, 0, IV_SIZE))
            val bytes = cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE)
            _status.value = baseStatus()
            Read.Key(bytes)
        } catch (_: KeyPermanentlyInvalidatedException) {
            ptLog(PtLog.Level.WARNING, "shell: vault key invalidated; keys deleted")
            wipe()
            _status.value = baseStatus()
            Read.Unavailable
        } catch (_: UserNotAuthenticatedException) {
            _status.value = ShellKeyStatus.LOCKED
            Read.Locked
        } catch (e: Exception) {
            ptLog(PtLog.Level.ERROR, "shell: vault read failed (${e.javaClass.simpleName})")
            Read.Missing
        }
    }

    /** Forget this Mac. */
    @Synchronized
    fun delete(macID: String) {
        prefs.edit().remove(entry(macID)).putStringSet(LOST_MACS, lost() - macID).commit()
        _status.value = ShellLostKeys.afterDelete(_status.value, baseStatus())
    }

    /** Forget every Mac: entries, the lost marker and the Keystore key. */
    @Synchronized
    fun deleteAll() {
        prefs.edit().clear().commit()
        deleteAlias()
        _status.value = baseStatus()
    }

    /**
     * Deletes the keys of Macs no longer paired. Skipped when [macIDs] is
     * empty, so a failed registry read can't wipe the vault.
     */
    @Synchronized
    fun prune(macIDs: Set<String>) {
        if (macIDs.isEmpty()) return
        val keep = macIDs.map(::entry).toSet()
        val stale = prefs.all.keys.filter { it.startsWith(ENTRY_PREFIX) && it !in keep }
        val lost = lost()
        val stillLost = ShellLostKeys.afterPrune(lost, macIDs)
        if (stale.isEmpty() && stillLost == lost) return
        prefs.edit().apply { stale.forEach { remove(it) } }.putStringSet(LOST_MACS, stillLost).commit()
        _status.value = baseStatus()
    }

    // Private

    private fun baseStatus(): ShellKeyStatus = when {
        !supported -> ShellKeyStatus.UNSUPPORTED
        !deviceSecure -> ShellKeyStatus.NEEDS_PASSCODE
        prefs.getBoolean(LEGACY_LOST, false) || lost().isNotEmpty() -> ShellKeyStatus.KEY_UNAVAILABLE
        else -> ShellKeyStatus.READY
    }

    private fun store(macID: String, key: ByteArray): Stored = try {
        val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, existingKey() ?: newKey()) }
        val blob = cipher.iv + cipher.doFinal(key)
        if (prefs.edit().putString(entry(macID), Base64.encodeToString(blob, Base64.NO_WRAP)).commit()) Stored.OK else Stored.FAILED
    } catch (_: KeyPermanentlyInvalidatedException) {
        Stored.INVALIDATED
    } catch (_: UserNotAuthenticatedException) {
        Stored.LOCKED
    } catch (e: Exception) {
        ptLog(PtLog.Level.ERROR, "shell: vault store failed (${e.javaClass.simpleName})")
        Stored.FAILED
    }

    /** The vault key was invalidated: its entries can never be read again, so their Macs' keys are lost. */
    private fun wipe() {
        val stale = prefs.all.keys.filter { it.startsWith(ENTRY_PREFIX) }
        val lost = ShellLostKeys.afterWipe(lost(), stale.map { it.removePrefix(ENTRY_PREFIX) })
        prefs.edit().apply { stale.forEach { remove(it) } }.putStringSet(LOST_MACS, lost).commit()
        deleteAlias()
    }

    /** The Macs whose keys were lost (a copy: never mutate what prefs return). */
    private fun lost(): Set<String> = prefs.getStringSet(LOST_MACS, null)?.toSet() ?: emptySet()

    private fun setLost(lost: Set<String>) {
        if (lost != lost()) prefs.edit().putStringSet(LOST_MACS, lost).commit()
    }

    /**
     * An older vault kept one "lost" flag for every Mac: count each granted
     * Mac without a stored key as lost, then drop the flag. Call on load, not
     * only when a key is pending.
     */
    @Synchronized
    fun migrateLegacyLost(registry: PairingRegistry) {
        if (!prefs.getBoolean(LEGACY_LOST, false)) return
        val granted = registry.clients.filter { it.shell != null }.map { it.id }
        val unkeyed = granted.filter { !prefs.contains(entry(it)) }
        prefs.edit().putStringSet(LOST_MACS, ShellLostKeys.afterLegacyMigration(lost(), unkeyed)).remove(LEGACY_LOST).commit()
        if (_status.value != ShellKeyStatus.LOCKED) _status.value = baseStatus()
    }

    private fun keyStore() = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private fun existingKey(): SecretKey? = keyStore().getKey(ALIAS, null) as? SecretKey

    private fun deleteAlias() {
        runCatching { keyStore().deleteEntry(ALIAS) }
    }

    @Suppress("DEPRECATION")
    private fun newKey(): SecretKey {
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            // Explicit: re-enrolling a biometric must not destroy the shell keys.
            .setInvalidatedByBiometricEnrollment(false)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(AUTH_WINDOW_SECONDS,
                        KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                } else {
                    setUserAuthenticationValidityDurationSeconds(AUTH_WINDOW_SECONDS)
                }
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).apply { init(spec) }.generateKey()
    }

    private fun entry(macID: String) = ENTRY_PREFIX + macID

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "passthrough.shell"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val AUTH_WINDOW_SECONDS = 60
        const val ENTRY_PREFIX = "shell."
        /** The Macs whose keys went when the vault key was invalidated; each leaves when it grants a key again. */
        const val LOST_MACS = "vault.lostMacs"
        /** The single flag an older vault kept instead; migrated by [migrateLegacyLost]. */
        const val LEGACY_LOST = "vault.lost"
    }
}
