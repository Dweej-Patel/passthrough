package dev.dpatel.passthrough.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.interfaces.ECPublicKey

class ShellKeySealTests {
    private val pair = ShellKeySeal.newKeyPair()
    private val public = pair.public as ECPublicKey
    private val key = ByteArray(32) { it.toByte() }

    @Test fun roundTripAndFormat() {
        val sealed = ShellKeySeal.seal(key, public, "mac1")
        assertEquals(1 + 65 + 12 + 32 + 16, sealed.size)
        assertEquals(ShellKeySeal.VERSION, sealed[0].toInt())
        assertEquals(ShellKeySeal.Format.SEALED, ShellKeySeal.format(sealed))
        assertArrayEquals(key, ShellKeySeal.open(sealed, "mac1", pair.private, public))
        assertFalse("a fresh ephemeral key each time", sealed.contentEquals(ShellKeySeal.seal(key, public, "mac1")))
        // The public half survives its X9.63 form, as the service reads it back.
        assertArrayEquals(ShellKeySeal.x963(public), ShellKeySeal.x963(ShellKeySeal.publicKey(ShellKeySeal.x963(public))!!))
    }

    @Test fun tamperedWrongMacOrWrongKeyDoesNotOpen() {
        val sealed = ShellKeySeal.seal(key, public, "mac1")
        for (i in listOf(1, 40, 70, sealed.size - 20, sealed.size - 1)) {
            val altered = sealed.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
            assertNull("byte $i", ShellKeySeal.open(altered, "mac1", pair.private, public))
        }
        assertNull("sealed for another Mac", ShellKeySeal.open(sealed, "mac2", pair.private, public))
        val other = ShellKeySeal.newKeyPair()
        assertNull("sealed to another key", ShellKeySeal.open(sealed, "mac1", other.private, other.public as ECPublicKey))
        assertNull(ShellKeySeal.open(sealed.copyOf(sealed.size - 1), "mac1", pair.private, public))
        val otherVersion = sealed.copyOf().also { it[0] = 2 }
        assertEquals(ShellKeySeal.Format.UNKNOWN, ShellKeySeal.format(otherVersion))
    }

    @Test fun adoptionDiscardsOldEntriesAndKeepsWhatTheLockedVaultCantOpen() {
        val sealed = ShellKeySeal.seal(key, public, "mac1")
        val halves = pair.private to public
        val opened = ShellKeySeal.adopt(sealed, "mac1", halves)
        assertTrue(opened is ShellKeySeal.Adoption.Key)
        assertArrayEquals(key, (opened as ShellKeySeal.Adoption.Key).bytes)
        // A bare key an older build stored: discarded, the Mac grants again.
        assertEquals(ShellKeySeal.Format.PLAIN, ShellKeySeal.format(key))
        assertEquals(ShellKeySeal.Adoption.Discard, ShellKeySeal.adopt(key, "mac1", halves))
        assertEquals(ShellKeySeal.Adoption.Discard, ShellKeySeal.adopt(key, "mac1", null))
        assertEquals(ShellKeySeal.Adoption.Discard, ShellKeySeal.adopt(byteArrayOf(1, 2, 3), "mac1", halves))
        assertEquals(ShellKeySeal.Adoption.Discard, ShellKeySeal.adopt(sealed, "mac2", halves))
        // The vault is locked: no sealing key to open it with now.
        assertEquals(ShellKeySeal.Adoption.Keep, ShellKeySeal.adopt(sealed, "mac1", null))
    }

    @Test fun keyPairRoundTripsAsTheVaultKeepsIt() {
        val decoded = ShellKeySeal.decodeKeyPair(ShellKeySeal.encodeKeyPair(pair))
        assertNotNull(decoded)
        val sealed = ShellKeySeal.seal(key, decoded!!.second, "mac1")
        assertArrayEquals(key, ShellKeySeal.open(sealed, "mac1", decoded.first, decoded.second))
        assertNull(ShellKeySeal.decodeKeyPair(ByteArray(10)))
        assertNull(ShellKeySeal.publicKey(ByteArray(65)))
    }

    @Test fun registryPublishesTheSealingKey() {
        val store = MemoryStore()
        val registry = PairingRegistry(store)
        assertNull(registry.shellSealingKey)
        registry.publishShellSealingKey(ShellKeySeal.x963(public))
        // The service's registry, on the same store, sees it.
        assertArrayEquals(ShellKeySeal.x963(public), ShellKeySeal.x963(PairingRegistry(store).shellSealingKey!!))
        registry.publishShellSealingKey(null)
        assertNull(registry.shellSealingKey)
    }
}
