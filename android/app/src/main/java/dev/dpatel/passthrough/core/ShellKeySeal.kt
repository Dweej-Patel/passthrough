package dev.dpatel.passthrough.core

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * How a shell key a Mac grants over the cable waits for the app: sealed to
 * the app's sealing key, whose private half lives in the shell key vault
 * (service/ShellKeyVault.kt), so it opens only with the app's unlock. The
 * service holds just the public half, so what it stores is useless until
 * then. Mirrors PassthroughCore/ShellKeySeal.swift, byte for byte;
 * protocol/fixtures.json has a vector both open.
 *
 * ECIES over P-256: an ephemeral key agrees with the sealing key; HKDF-SHA256
 * (no salt, info = [INFO_LABEL] ‖ ephemeral public key ‖ sealing public key,
 * both X9.63) gives a 256-bit AES-GCM key; the Mac's ID is the associated
 * data, so a sealed key can't pass for another Mac's.
 *
 * `[version 1][ephemeral public key, X9.63, 65][nonce 12][ciphertext][tag 16]`
 */
object ShellKeySeal {
    const val VERSION = 1
    private val INFO_LABEL = "passthrough.shell.pending.v1".toByteArray()
    private const val PUBLIC_KEY_SIZE = 65
    private const val NONCE_SIZE = 12
    private const val TAG_BITS = 128
    private const val OVERHEAD = 1 + PUBLIC_KEY_SIZE + NONCE_SIZE + TAG_BITS / 8

    enum class Format {
        SEALED,
        /** A bare 32-byte key, as builds before sealing stored it: discarded, the Mac grants again. */
        PLAIN,
        UNKNOWN,
    }

    fun format(stored: ByteArray): Format = when {
        stored.size == 32 -> Format.PLAIN
        stored.size > OVERHEAD && stored[0].toInt() == VERSION -> Format.SEALED
        else -> Format.UNKNOWN
    }

    fun associatedData(clientID: String): ByteArray = "passthrough.shell.key:".toByteArray() + clientID.toByteArray(Charsets.UTF_8)

    // Keys

    private val p256: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    /** X9.63: 0x04 ‖ X ‖ Y, 32 bytes each. */
    fun x963(key: ECPublicKey): ByteArray = byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)

    /** Null when [bytes] isn't an uncompressed P-256 point. */
    fun publicKey(bytes: ByteArray): ECPublicKey? {
        if (bytes.size != PUBLIC_KEY_SIZE || bytes[0].toInt() != 4) return null
        return try {
            val point = ECPoint(BigInteger(1, bytes.copyOfRange(1, 33)), BigInteger(1, bytes.copyOfRange(33, 65)))
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, p256)) as ECPublicKey
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    /** The sealing key pair as the vault keeps it: `[public key, X9.63, 65][private key, PKCS#8]`. */
    fun encodeKeyPair(pair: KeyPair): ByteArray = x963(pair.public as ECPublicKey) + pair.private.encoded

    /** Null when [bytes] isn't what [encodeKeyPair] wrote. */
    fun decodeKeyPair(bytes: ByteArray): Pair<PrivateKey, ECPublicKey>? {
        if (bytes.size <= PUBLIC_KEY_SIZE) return null
        val publicHalf = publicKey(bytes.copyOfRange(0, PUBLIC_KEY_SIZE)) ?: return null
        val privateHalf = runCatching {
            KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(bytes.copyOfRange(PUBLIC_KEY_SIZE, bytes.size)))
        }.getOrNull() ?: return null
        return privateHalf to publicHalf
    }

    /** A private key from its raw 32-byte scalar (test vectors). */
    fun privateKeyFromScalar(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), p256))

    private fun fixed(n: BigInteger): ByteArray {
        val b = n.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }

    // Sealing

    fun seal(key: ByteArray, recipient: ECPublicKey, clientID: String): ByteArray {
        val ephemeral = newKeyPair()
        val ephemeralPublic = x963(ephemeral.public as ECPublicKey)
        val aes = derive(agree(ephemeral.private, recipient), ephemeralPublic, x963(recipient))
        val nonce = ByteArray(NONCE_SIZE).also { java.security.SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(aes, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(associatedData(clientID))
        return byteArrayOf(VERSION.toByte()) + ephemeralPublic + nonce + cipher.doFinal(key)
    }

    /** Null when [sealed] isn't a sealed entry this build reads, was altered, or was sealed to another key or Mac. */
    fun open(sealed: ByteArray, clientID: String, privateKey: PrivateKey, publicKey: ECPublicKey): ByteArray? {
        if (format(sealed) != Format.SEALED) return null
        val ephemeralBytes = sealed.copyOfRange(1, 1 + PUBLIC_KEY_SIZE)
        val ephemeral = publicKey(ephemeralBytes) ?: return null
        return try {
            val aes = derive(agree(privateKey, ephemeral), ephemeralBytes, x963(publicKey))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(aes, "AES"), GCMParameterSpec(TAG_BITS, sealed, 1 + PUBLIC_KEY_SIZE, NONCE_SIZE))
            cipher.updateAAD(associatedData(clientID))
            val start = 1 + PUBLIC_KEY_SIZE + NONCE_SIZE
            cipher.doFinal(sealed, start, sealed.size - start)
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    /** What the app does with a pending entry at an unlock. */
    sealed interface Adoption {
        /** Opened: into the vault with it, then delete the entry. */
        class Key(val bytes: ByteArray) : Adoption
        /** An older build's bare key, or nothing this build can open: delete it; the Mac grants again over the cable. */
        data object Discard : Adoption
        /** The sealing key isn't available just now (the vault is locked): leave it for the next unlock. */
        data object Keep : Adoption
    }

    /** [sealing]: the private and public halves, or null while the vault can't give them. */
    fun adopt(stored: ByteArray, clientID: String, sealing: Pair<PrivateKey, ECPublicKey>?): Adoption {
        if (format(stored) != Format.SEALED) return Adoption.Discard
        val (ownPrivate, ownPublic) = sealing ?: return Adoption.Keep
        return open(stored, clientID, ownPrivate, ownPublic)?.let(Adoption::Key) ?: Adoption.Discard
    }

    private fun agree(ownKey: PrivateKey, peer: ECPublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").apply { init(ownKey); doPhase(peer, true) }.generateSecret()

    /** HKDF-SHA256 (RFC 5869), no salt, 32 bytes. */
    private fun derive(shared: ByteArray, ephemeral: ByteArray, recipient: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
        val prk = mac.doFinal(shared)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(INFO_LABEL); mac.update(ephemeral); mac.update(recipient); mac.update(1.toByte())
        return mac.doFinal()
    }
}
