package dev.dpatel.passthrough.service

import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import dev.dpatel.passthrough.core.PairingRegistry
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ShellKeySeal
import dev.dpatel.passthrough.core.ShellKeyStatus
import dev.dpatel.passthrough.core.ShellLostKeys
import dev.dpatel.passthrough.core.ShellVaultBlob
import dev.dpatel.passthrough.core.ptLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.ProviderException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The app's private home for remote-shell keys. A key a Mac grants over the
 * cable waits as "pending" in the registry's secret store; right after each
 * app unlock [adoptPending] moves it here. Android invalidates the vault's
 * Keystore key when the lock screen is removed; enrolling another face or
 * fingerprint does not. The vault never prompts: when it needs an
 * authentication it reports [ShellKeyStatus.LOCKED] and the app lock asks for
 * a fresh unlock (the user taps Unlock). Mirrors iOS/App/Shell/ShellKeyVault.swift.
 *
 * Android 11 and later: every key is in one blob ([ShellVaultBlob]) behind a
 * Keystore key that needs an authentication for each use, so unlocking the
 * phone itself never opens it. The app's own unlock prompt carries the
 * vault's cipher ([unlockCipher], [authorize]): that one prompt unwraps the
 * blob's data key (or wraps a new one), which opens every Mac's key and seals
 * new grants until the app locks again ([lock]). Entries an older version
 * stored per Mac move into the blob on the first such unlock.
 *
 * Android 10: one entry per Mac behind a key usable for 60 seconds after any
 * authentication, as before (it can't take a device credential per use).
 *
 * The vault also keeps the private half of the sealing key ([ShellKeySeal],
 * [prepareSealing]): the service seals each key a Mac grants to its public
 * half, so a pending key opens only with this vault, at an unlock.
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

    /** The Keystore failed for now: what the vault holds stays, for a later try. */
    private class VaultBusy : Exception("vault busy")

    private val keyguard = context.getSystemService(KeyguardManager::class.java)
    private val prefs = context.applicationContext.getSharedPreferences("shell_vault", Context.MODE_PRIVATE)
    private val strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
    private val _status = MutableStateFlow(baseStatus())
    val status: StateFlow<ShellKeyStatus> = _status.asStateFlow()

    /** Remote shell needs API 29+ (TLS 1.3). */
    val supported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /** False when the device has no secure lock screen: the vault can't hold keys then. */
    val deviceSecure: Boolean get() = keyguard?.isDeviceSecure == true

    /** Android 11+: one blob behind a key that needs an authentication for each use. */
    private val perUse: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    /**
     * The blob's data key, from the unlock prompt's cipher. Held while the app
     * is unlocked, as the keys it opens are; [lock] drops it.
     */
    private var dataKey: ByteArray? = null
    /** The unlock prompt's cipher, authorized for one operation, until the vault uses it. */
    private var authorized: Cipher? = null
    /** Whether [authorized] wraps a new data key (no blob yet) rather than unwrapping the stored one. */
    private var authorizedWraps = false
    /** The sealing key pair as the blob holds it ([ShellKeySeal.encodeKeyPair]); read with the blob, kept by every write. */
    private var blobSealing: ByteArray? = null

    // Unlock (Android 11+)

    /**
     * The cipher the app's unlock prompt should carry in its CryptoObject, or
     * null when the vault needs none: Android 10 or no lock screen. Unwraps
     * the stored data key, or wraps a new one for a new vault (which at least
     * holds the sealing key pending grants are sealed to).
     */
    @Synchronized
    fun unlockCipher(registry: PairingRegistry): Cipher? {
        if (!perUse || !supported || !deviceSecure) return null
        lock()
        val wrapped = prefs.getString(WRAPPED_KEY, null)
        return try {
            if (wrapped != null) {
                val blob = Base64.decode(wrapped, Base64.NO_WRAP)
                val key = existingKey(ALIAS) ?: throw KeyPermanentlyInvalidatedException()
                authorizedWraps = false
                Cipher.getInstance(TRANSFORM).apply { init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, blob, 0, IV_SIZE)) }
            } else {
                wrapCipher(registry)
            }
        } catch (_: KeyPermanentlyInvalidatedException) {
            ptLog(PtLog.Level.WARNING, "shell: vault key invalidated; keys deleted")
            wipeBlob()
            // Its sealing key went with it: the service must not seal to it any more.
            registry.publishShellSealingKey(null)
            _status.value = baseStatus()
            // A new vault, with a new sealing key, comes with this same prompt.
            runCatching { wrapCipher(registry) }.getOrNull()
        } catch (e: Exception) {
            ptLog(PtLog.Level.ERROR, "shell: vault cipher unavailable (${e.javaClass.simpleName})")
            null
        }
    }

    /** A cipher to wrap a new vault's data key with. */
    @Suppress("UNUSED_PARAMETER")
    private fun wrapCipher(registry: PairingRegistry): Cipher? {
        authorizedWraps = true
        return Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, existingKey(ALIAS) ?: newKey(ALIAS, perUse = true)) }
    }

    /** The unlock prompt succeeded: [cipher] (from [unlockCipher]) is authorized for the vault's one operation. */
    @Synchronized
    fun authorize(cipher: Cipher) { authorized = cipher }

    /** The app locked: forget the data key until the next unlock prompt. */
    @Synchronized
    fun lock() {
        dataKey?.fill(0)
        dataKey = null
        blobSealing?.fill(0)
        blobSealing = null
        authorized = null
    }

    /**
     * Makes sure the vault holds a sealing key and the service has its public
     * half to seal grants with; creates one on first use. Quiet when the vault
     * can't be opened right now (the next unlock does it).
     */
    @Synchronized
    fun prepareSealing(registry: PairingRegistry) {
        if (!supported || !deviceSecure) return
        val pair = try {
            if (perUse) blobSealingPair(create = true) else entrySealingPair(create = true)
        } catch (_: UserNotAuthenticatedException) {
            null
        } catch (e: Exception) {
            ptLog(PtLog.Level.ERROR, "shell: sealing key unavailable (${e.javaClass.simpleName})")
            null
        }
        val publicHalf = pair?.second?.let(ShellKeySeal::x963) ?: return
        if (registry.shellSealingKey?.let(ShellKeySeal::x963)?.contentEquals(publicHalf) != true) {
            registry.publishShellSealingKey(publicHalf)
            ptLog(PtLog.Level.INFO, "shell: sealing key published")
        }
    }

    // Keys

    /**
     * Moves every pending key into the vault and clears it from the pending
     * store. Without a secure lock screen nothing moves (keys stay pending).
     * Returns how many moved.
     */
    @Synchronized
    fun adoptPending(registry: PairingRegistry): Int {
        if (!supported || !deviceSecure) return 0.also { _status.value = baseStatus() }
        migrateLegacyLost(registry)
        if (perUse) {
            return try {
                adoptIntoBlob(registry)
            } catch (e: Exception) {
                ptLog(PtLog.Level.ERROR, "shell: vault adoption failed (${e.javaClass.simpleName}); keys stay pending")
                0.also { _status.value = baseStatus() }
            }
        }
        var moved = 0
        // Its 60 s window passed: what is sealed waits for the next unlock.
        var locked = false
        val sealing = try {
            entrySealingPair(create = false)
        } catch (_: UserNotAuthenticatedException) {
            locked = true
            null
        } catch (e: Exception) {
            // Not a missing sealing key (that discards what is sealed): the
            // Keystore failed for now, so everything waits for the next unlock.
            ptLog(PtLog.Level.ERROR, "shell: sealing key unreadable (${e.javaClass.simpleName}); keys stay pending")
            return 0.also { _status.value = baseStatus() }
        }
        for (client in registry.clients) {
            if (client.shell == null) continue
            val stored = registry.sealedPendingShellKey(client.id) ?: continue
            val key = when (val adoption = ShellKeySeal.adopt(stored, client.id, sealing)) {
                is ShellKeySeal.Adoption.Key -> adoption.bytes
                ShellKeySeal.Adoption.Keep -> if (locked) {
                    _status.value = ShellKeyStatus.LOCKED
                    return moved
                } else {
                    // No sealing key here to open it with: it can never open.
                    discarded(registry, client.id, stored); continue
                }
                ShellKeySeal.Adoption.Discard -> { discarded(registry, client.id, stored); continue }
            }
            var result = store(client.id, key)
            if (result == Stored.INVALIDATED) {
                wipeEntries()
                result = store(client.id, key)
            }
            when (result) {
                Stored.OK -> {
                    adopted(registry, client.id, stored)
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

    private fun adoptIntoBlob(registry: PairingRegistry): Int {
        var pending = registry.clients.filter { it.shell != null }
            .mapNotNull { client -> registry.sealedPendingShellKey(client.id)?.let { client.id to it } }
        // An older build's bare key goes whether or not the vault opens.
        pending.filter { (_, stored) -> ShellKeySeal.format(stored) != ShellKeySeal.Format.SEALED }
            .forEach { (id, stored) -> discarded(registry, id, stored) }
        pending = pending.filter { (_, stored) -> ShellKeySeal.format(stored) == ShellKeySeal.Format.SEALED }
        if (pending.isEmpty()) return 0.also { _status.value = baseStatus() }
        val keys = when (val open = openBlob()) {
            is Opened.Keys -> open.keys
            Opened.Locked -> return 0.also { _status.value = ShellKeyStatus.LOCKED }
            Opened.Invalidated, Opened.Failed -> return 0.also { _status.value = baseStatus() }
        }
        val sealing = blobSealingPair(create = false)
        val opened = HashMap<String, ByteArray>()
        for ((id, stored) in pending) {
            when (val adoption = ShellKeySeal.adopt(stored, id, sealing)) {
                is ShellKeySeal.Adoption.Key -> opened[id] = adoption.bytes
                ShellKeySeal.Adoption.Discard, ShellKeySeal.Adoption.Keep -> discarded(registry, id, stored)
            }
        }
        if (opened.isEmpty() || !writeBlob(keys + opened)) return 0.also { _status.value = baseStatus() }
        pending.filter { it.first in opened }.forEach { (id, stored) -> adopted(registry, id, stored) }
        _status.value = baseStatus()
        ptLog(PtLog.Level.INFO, "shell: adopted ${opened.size} key(s)")
        return opened.size
    }

    /** [macID]'s key, pending as [stored], is in the vault: clear that pending entry and the Mac's loss. */
    private fun adopted(registry: PairingRegistry, macID: String, stored: ByteArray) {
        // A newer grant may have landed meanwhile: leave that one for the next unlock.
        if (registry.sealedPendingShellKey(macID)?.contentEquals(stored) == true) registry.clearPendingShellKey(macID)
        // Only this Mac's loss is over: others' keys stay lost until they grant again.
        setLost(ShellLostKeys.afterAdopt(lost(), macID))
    }

    /**
     * [macID]'s pending entry can never be opened (an older build's bare key, sealed to a
     * sealing key since replaced, altered): delete it. The Mac grants again on its next
     * cable connection.
     */
    private fun discarded(registry: PairingRegistry, macID: String, stored: ByteArray) {
        if (registry.sealedPendingShellKey(macID)?.contentEquals(stored) == true) registry.clearPendingShellKey(macID)
        ptLog(PtLog.Level.INFO, "shell: discarded a pending key this version can't open; the Mac grants again over the cable")
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
        if (perUse) {
            // Nothing stored for this Mac: no need to open the blob (or ask for an unlock) to say so.
            if (macID !in blobMacs() && !prefs.contains(entry(macID))) return Read.Missing
            return when (val open = openBlob()) {
                is Opened.Keys -> when {
                    macID in open.keys -> Read.Key(open.keys.getValue(macID)).also { _status.value = baseStatus() }
                    // Its older entry couldn't move in yet (its 60 s window passed): a fresh unlock will.
                    prefs.contains(entry(macID)) -> Read.Locked.also { _status.value = ShellKeyStatus.LOCKED }
                    else -> Read.Missing
                }
                Opened.Locked -> Read.Locked.also { _status.value = ShellKeyStatus.LOCKED }
                Opened.Invalidated -> Read.Unavailable.also { _status.value = baseStatus() }
                Opened.Failed -> Read.Missing
            }
        }
        val raw = prefs.getString(entry(macID), null) ?: return Read.Missing
        return try {
            val bytes = decryptEntry(raw) ?: return Read.Missing
            _status.value = baseStatus()
            Read.Key(bytes)
        } catch (_: KeyPermanentlyInvalidatedException) {
            ptLog(PtLog.Level.WARNING, "shell: vault key invalidated; keys deleted")
            wipeEntries()
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
        if (perUse) dropFromBlob(setOf(macID))
        _status.value = ShellLostKeys.afterDelete(_status.value, baseStatus())
    }

    /** Forget every Mac: entries, the blob, the lost marker and the Keystore keys. */
    @Synchronized
    fun deleteAll() {
        lock()
        prefs.edit().clear().commit()
        deleteAlias(ALIAS)
        deleteAlias(LEGACY_ALIAS)
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
        val staleInBlob = if (perUse) blobMacs() - macIDs else emptySet()
        val lost = lost()
        val stillLost = ShellLostKeys.afterPrune(lost, macIDs)
        if (stale.isEmpty() && staleInBlob.isEmpty() && stillLost == lost) return
        prefs.edit().apply { stale.forEach { remove(it) } }.putStringSet(LOST_MACS, stillLost).commit()
        if (staleInBlob.isNotEmpty()) dropFromBlob(staleInBlob)
        _status.value = baseStatus()
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
        val stored = blobMacs()
        val unkeyed = granted.filter { !prefs.contains(entry(it)) && it !in stored }
        prefs.edit().putStringSet(LOST_MACS, ShellLostKeys.afterLegacyMigration(lost(), unkeyed)).remove(LEGACY_LOST).commit()
        if (_status.value != ShellKeyStatus.LOCKED) _status.value = baseStatus()
    }

    // Private: the blob (Android 11+)

    private sealed interface Opened {
        class Keys(val keys: Map<String, ByteArray>) : Opened
        /** No data key: the app needs an unlock whose prompt carries the vault's cipher. */
        data object Locked : Opened
        /** The vault's key was invalidated: its keys are lost. */
        data object Invalidated : Opened
        data object Failed : Opened
    }

    /**
     * The data key: held, or from the cipher the unlock prompt just
     * authorized. Null when it is ready, else why it isn't.
     */
    private fun session(): Opened? {
        if (dataKey != null) return null
        val cipher = authorized ?: return Opened.Locked
        authorized = null
        return try {
            dataKey = if (authorizedWraps) {
                val key = ShellVaultBlob.newDataKey()
                val wrapped = cipher.iv + cipher.doFinal(key)
                // A new data key starts a new blob.
                val ok = prefs.edit().putString(WRAPPED_KEY, Base64.encodeToString(wrapped, Base64.NO_WRAP))
                    .remove(BLOB).remove(BLOB_MACS).remove(BLOB_REMOVED).commit()
                if (!ok) return Opened.Failed
                key
            } else {
                val wrapped = Base64.decode(prefs.getString(WRAPPED_KEY, null) ?: return Opened.Locked, Base64.NO_WRAP)
                cipher.doFinal(wrapped, IV_SIZE, wrapped.size - IV_SIZE)
            }
            null
        } catch (_: KeyPermanentlyInvalidatedException) {
            ptLog(PtLog.Level.WARNING, "shell: vault key invalidated; keys deleted")
            wipeBlob()
            Opened.Invalidated
        } catch (_: UserNotAuthenticatedException) {
            Opened.Locked
        } catch (e: Exception) {
            ptLog(PtLog.Level.ERROR, "shell: vault unlock failed (${e.javaClass.simpleName})")
            Opened.Failed
        }
    }

    /** Every key in the vault, the older per-Mac entries moved in first. */
    private fun openBlob(): Opened {
        session()?.let { return it }
        val key = dataKey ?: return Opened.Locked
        val removed = prefs.getStringSet(BLOB_REMOVED, null)?.toSet() ?: emptySet()
        val sealed = prefs.getString(BLOB, null)
        // Written back when it isn't exactly what is stored.
        var rewrite = sealed == null || removed.isNotEmpty()
        var keys = if (sealed == null) emptyMap() else {
            val contents = ShellVaultBlob.open(key, Base64.decode(sealed, Base64.NO_WRAP))
            if (contents == null) {
                // Unreadable with its own data key: nothing in it can come back.
                ptLog(PtLog.Level.ERROR, "shell: vault unreadable; keys deleted")
                setLost(ShellLostKeys.afterWipe(lost(), blobMacs()))
                rewrite = true
            }
            blobSealing = contents?.sealingKey
            contents?.keys ?: emptyMap()
        }
        keys = keys - removed
        val legacy = legacyEntries()
        if (legacy.isEmpty()) {
            if (rewrite) writeBlob(keys)
            return Opened.Keys(keys)
        }
        val migration = ShellVaultBlob.migrate(keys, legacy.mapValues { (_, raw) -> readEntry(raw) })
        if (!writeBlob(migration.keys)) return Opened.Keys(keys)
        prefs.edit().apply { migration.migrated.forEach { remove(entry(it)) } }
            .putStringSet(LOST_MACS, ShellLostKeys.afterWipe(lost(), migration.lost)).commit()
        if (migration.lost.isNotEmpty()) ptLog(PtLog.Level.WARNING, "shell: ${migration.lost.size} older key(s) unreadable; deleted")
        if (legacyEntries().isEmpty()) deleteAlias(LEGACY_ALIAS)
        return Opened.Keys(migration.keys)
    }

    /** Seals [keys] (and the sealing key) as the whole blob with the held data key. */
    private fun writeBlob(keys: Map<String, ByteArray>): Boolean {
        val key = dataKey ?: return false
        val sealed = ShellVaultBlob.seal(key, ShellVaultBlob.Contents(keys, blobSealing))
        return prefs.edit().putString(BLOB, Base64.encodeToString(sealed, Base64.NO_WRAP))
            .putStringSet(BLOB_MACS, keys.keys.toSet()).remove(BLOB_REMOVED).commit()
    }

    /**
     * Takes [macIDs]' keys out of the blob: now if the data key is held, else
     * at the next unlock (listed as removed meanwhile, so they're never read).
     */
    private fun dropFromBlob(macIDs: Set<String>) {
        val inBlob = blobMacs()
        if (macIDs.none { it in inBlob }) return
        val keys = (openBlob() as? Opened.Keys)?.keys
        if (keys != null && writeBlob(keys - macIDs)) return
        val removed = (prefs.getStringSet(BLOB_REMOVED, null)?.toSet() ?: emptySet()) + macIDs
        prefs.edit().putStringSet(BLOB_REMOVED, removed).putStringSet(BLOB_MACS, inBlob - macIDs).commit()
    }

    /** The Macs with a key in the blob: kept in the clear (Mac IDs aren't secret) to say what was lost. */
    private fun blobMacs(): Set<String> = prefs.getStringSet(BLOB_MACS, null)?.toSet() ?: emptySet()

    /** The blob's sealing key pair, made (and written) on first use when [create]; null while the blob is locked. */
    private fun blobSealingPair(create: Boolean): Pair<java.security.PrivateKey, java.security.interfaces.ECPublicKey>? {
        val keys = (openBlob() as? Opened.Keys)?.keys ?: return null
        blobSealing?.let(ShellKeySeal::decodeKeyPair)?.let { return it }
        if (!create) return null
        val fresh = ShellKeySeal.encodeKeyPair(ShellKeySeal.newKeyPair())
        val previous = blobSealing
        blobSealing = fresh
        if (!writeBlob(keys)) { blobSealing = previous; return null }
        return ShellKeySeal.decodeKeyPair(fresh)
    }

    /** The vault key was invalidated: the blob can never be read again, so its Macs' keys are lost. */
    private fun wipeBlob() {
        val lost = ShellLostKeys.afterWipe(lost(), blobMacs())
        prefs.edit().remove(WRAPPED_KEY).remove(BLOB).remove(BLOB_MACS).remove(BLOB_REMOVED).putStringSet(LOST_MACS, lost).commit()
        lock()
        deleteAlias(ALIAS)
    }

    // Private: per-Mac entries (Android 10, and what older versions stored)

    private fun baseStatus(): ShellKeyStatus = when {
        !supported -> ShellKeyStatus.UNSUPPORTED
        !deviceSecure -> ShellKeyStatus.NEEDS_PASSCODE
        prefs.getBoolean(LEGACY_LOST, false) || lost().isNotEmpty() -> ShellKeyStatus.KEY_UNAVAILABLE
        else -> ShellKeyStatus.READY
    }

    /** Older per-Mac entries, by Mac. */
    private fun legacyEntries(): Map<String, String> = prefs.all.entries
        .filter { it.key.startsWith(ENTRY_PREFIX) }
        .mapNotNull { (k, v) -> (v as? String)?.let { k.removePrefix(ENTRY_PREFIX) to it } }
        .toMap()

    /** Null when the entry's Keystore key is gone. */
    private fun decryptEntry(raw: String): ByteArray? {
        val blob = Base64.decode(raw, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.DECRYPT_MODE, existingKey(LEGACY_ALIAS) ?: return null, GCMParameterSpec(128, blob, 0, IV_SIZE))
        return cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE)
    }

    /**
     * An older entry, for the move into the blob. Its key is time-bound: the
     * unlock prompt that just ran authorizes it.
     */
    private fun readEntry(raw: String): ShellVaultBlob.LegacyRead = try {
        decryptEntry(raw)?.let(ShellVaultBlob.LegacyRead::Key) ?: ShellVaultBlob.LegacyRead.Invalidated
    } catch (_: KeyPermanentlyInvalidatedException) {
        ShellVaultBlob.LegacyRead.Invalidated
    } catch (_: Exception) {
        ShellVaultBlob.LegacyRead.Retry
    }

    /**
     * Android 10: the sealing key pair, an entry like a Mac's key (usable for 60 s after an
     * authentication), made on first use when [create]. Throws [UserNotAuthenticatedException]
     * when that window has passed, and [VaultBusy] when the Keystore fails for now: the entry
     * stays then, with none made in its place (grants may be sealed to it). An entry altered
     * for good is discarded, as grants sealed to it can never open, and replaced when [create].
     */
    private fun entrySealingPair(create: Boolean): Pair<java.security.PrivateKey, java.security.interfaces.ECPublicKey>? {
        val raw = prefs.getString(SEALING_ENTRY, null)
        if (raw != null) {
            val read = try {
                ShellVaultBlob.readEntry { decryptEntry(raw)?.let(ShellKeySeal::decodeKeyPair) }
            } catch (_: KeyPermanentlyInvalidatedException) {
                wipeEntries()
                null
            } catch (e: UserNotAuthenticatedException) {
                throw e
            } catch (_: InvalidKeyException) {
                ShellVaultBlob.EntryRead.Retry
            }
            when (read) {
                is ShellVaultBlob.EntryRead.Value -> read.value?.let { return it }
                ShellVaultBlob.EntryRead.Corrupt -> {
                    ptLog(PtLog.Level.WARNING, "shell: sealing key unreadable; discarded")
                    prefs.edit().remove(SEALING_ENTRY).commit()
                }
                ShellVaultBlob.EntryRead.Retry -> throw VaultBusy()
                null -> Unit
            }
        }
        if (!create) return null
        val fresh = ShellKeySeal.encodeKeyPair(ShellKeySeal.newKeyPair())
        return if (store(SEALING_ENTRY, fresh, prefsKey = SEALING_ENTRY) == Stored.OK) ShellKeySeal.decodeKeyPair(fresh) else null
    }

    private fun store(macID: String, key: ByteArray, prefsKey: String = entry(macID)): Stored = try {
        val cipher = Cipher.getInstance(TRANSFORM).apply {
            init(Cipher.ENCRYPT_MODE, existingKey(LEGACY_ALIAS) ?: newKey(LEGACY_ALIAS, perUse = false))
        }
        val blob = cipher.iv + cipher.doFinal(key)
        if (prefs.edit().putString(prefsKey, Base64.encodeToString(blob, Base64.NO_WRAP)).commit()) Stored.OK else Stored.FAILED
    } catch (_: KeyPermanentlyInvalidatedException) {
        Stored.INVALIDATED
    } catch (_: UserNotAuthenticatedException) {
        Stored.LOCKED
    } catch (e: Exception) {
        ptLog(PtLog.Level.ERROR, "shell: vault store failed (${e.javaClass.simpleName})")
        Stored.FAILED
    }

    /** The entries' key was invalidated: they can never be read again, so their Macs' keys are lost. */
    private fun wipeEntries() {
        val stale = prefs.all.keys.filter { it.startsWith(ENTRY_PREFIX) }
        val lost = ShellLostKeys.afterWipe(lost(), stale.map { it.removePrefix(ENTRY_PREFIX) })
        prefs.edit().apply { stale.forEach { remove(it) } }.remove(SEALING_ENTRY).putStringSet(LOST_MACS, lost).commit()
        deleteAlias(LEGACY_ALIAS)
    }

    /** The Macs whose keys were lost (a copy: never mutate what prefs return). */
    private fun lost(): Set<String> = prefs.getStringSet(LOST_MACS, null)?.toSet() ?: emptySet()

    private fun setLost(lost: Set<String>) {
        if (lost != lost()) prefs.edit().putStringSet(LOST_MACS, lost).commit()
    }

    private fun keyStore() = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private fun existingKey(alias: String): SecretKey? = keyStore().getKey(alias, null) as? SecretKey

    private fun deleteAlias(alias: String) {
        runCatching { keyStore().deleteEntry(alias) }
    }

    /**
     * [perUse]: every use needs its own authentication (the unlock prompt's
     * CryptoObject); else any authentication in the last 60 s will do (Android 10).
     * In StrongBox when the phone has one, and never usable while the phone is locked.
     */
    @Suppress("DEPRECATION")
    private fun newKey(alias: String, perUse: Boolean): SecretKey {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            // Explicit: re-enrolling a biometric must not destroy the shell keys.
            .setInvalidatedByBiometricEnrollment(false)
            .apply {
                if (perUse && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                } else {
                    setUserAuthenticationValidityDurationSeconds(AUTH_WINDOW_SECONDS)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setUnlockedDeviceRequired(true)
                    if (strongBox) setIsStrongBoxBacked(true)
                }
            }
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        if (strongBox) {
            try {
                return generator.apply { init(spec(strongBox = true)) }.generateKey()
            } catch (_: ProviderException) {
                // StrongBoxUnavailableException (API 28+) is one; caught as its parent so older
                // phones never have to resolve it. Any StrongBox failure falls back to the TEE.
                ptLog(PtLog.Level.INFO, "shell: StrongBox unavailable; vault key in the TEE")
            }
        }
        return generator.apply { init(spec(strongBox = false)) }.generateKey()
    }

    private fun entry(macID: String) = ENTRY_PREFIX + macID

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        /** Android 11+: wraps the blob's data key; an authentication per use. */
        const val ALIAS = "passthrough.shell.v2"
        /** The per-Mac entries' key: Android 10, and what older versions stored. */
        const val LEGACY_ALIAS = "passthrough.shell"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val AUTH_WINDOW_SECONDS = 60
        const val ENTRY_PREFIX = "shell."
        /** Android 10: the sealing key pair, encrypted like a Mac's entry. Not under [ENTRY_PREFIX]. */
        const val SEALING_ENTRY = "vault.sealing"
        const val WRAPPED_KEY = "vault2.wrappedKey"
        const val BLOB = "vault2.blob"
        const val BLOB_MACS = "vault2.macs"
        /** Macs forgotten while the blob was locked: out of it at the next unlock, never read meanwhile. */
        const val BLOB_REMOVED = "vault2.removed"
        /** The Macs whose keys went when the vault key was invalidated; each leaves when it grants a key again. */
        const val LOST_MACS = "vault.lostMacs"
        /** The single flag an older vault kept instead; migrated by [migrateLegacyLost]. */
        const val LEGACY_LOST = "vault.lost"
    }
}
