package dev.dpatel.passthrough.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * How the Mac and a phone prove a pairing to each other (protocol version 2).
 * The token never goes on the wire after pairing: both sides prove they know
 * K = SHA-256(token), which is all the phone keeps, by an HMAC over a fresh
 * nonce from each side, the phone first. The SOCKS5 password is derived from
 * K too, so an app squatting the SOCKS port learns nothing it could use on the
 * control channel. Mirrors PassthroughCore/ControlAuth.swift.
 */
object ControlAuth {
    const val PHONE_LABEL = "passthrough-control-v2 phone"
    const val MAC_LABEL = "passthrough-control-v2 mac"
    const val SOCKS_LABEL = "passthrough-socks-v2"
    const val NONCE_LENGTH = 32
    private val random = SecureRandom()

    /** K, from the token the Mac keeps. */
    fun key(token: String): ByteArray = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))

    /** K, from the lowercase hex SHA-256 the phone keeps; null if it isn't one. */
    fun keyFromHash(tokenHash: String): ByteArray? {
        if (tokenHash.length != 64) return null
        val out = ByteArray(32)
        for (i in 0 until 32) {
            val hi = Character.digit(tokenHash[2 * i], 16)
            val lo = Character.digit(tokenHash[2 * i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = (hi shl 4 or lo).toByte()
        }
        return out
    }

    fun nonce(): ByteArray = ByteArray(NONCE_LENGTH).also { random.nextBytes(it) }

    /** A nonce from the wire: base64 of exactly [NONCE_LENGTH] bytes, else null. */
    fun decodeNonce(text: String?): ByteArray? =
        text?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }?.takeIf { it.size == NONCE_LENGTH }

    /** The phone's proof, in `welcome`: HMAC(K, PHONE_LABEL ‖ clientID ‖ macNonce ‖ phoneNonce). */
    fun phoneProof(key: ByteArray, clientID: String, macNonce: ByteArray, phoneNonce: ByteArray): ByteArray =
        hmac(key, message(PHONE_LABEL, clientID, macNonce, phoneNonce))

    /** The Mac's proof, in `auth`: HMAC(K, MAC_LABEL ‖ clientID ‖ phoneNonce ‖ macNonce). */
    fun macProof(key: ByteArray, clientID: String, macNonce: ByteArray, phoneNonce: ByteArray): ByteArray =
        hmac(key, message(MAC_LABEL, clientID, phoneNonce, macNonce))

    /** Constant-time check of the Mac's proof; false for anything not valid base64. */
    fun isValidMacProof(proof: String?, key: ByteArray, clientID: String, macNonce: ByteArray, phoneNonce: ByteArray): Boolean {
        val code = proof?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() } ?: return false
        return MessageDigest.isEqual(code, macProof(key, clientID, macNonce, phoneNonce))
    }

    /** The SOCKS5 password, HMAC(K, SOCKS_LABEL), as unpadded URL-safe base64: the shape of a token. */
    fun socksPassword(key: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(hmac(key, SOCKS_LABEL.toByteArray(Charsets.UTF_8)))

    private fun hmac(key: ByteArray, message: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(message) }

    /** The nonces have a fixed length and come last, so the client ID between the label and them can't be shifted into either. */
    private fun message(label: String, clientID: String, first: ByteArray, second: ByteArray): ByteArray =
        label.toByteArray(Charsets.UTF_8) + clientID.toByteArray(Charsets.UTF_8) + first + second
}
