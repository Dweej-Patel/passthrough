package dev.dpatel.passthrough.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ShellVaultBlobTests {
    private val a = ByteArray(32) { it.toByte() }
    private val b = ByteArray(32) { (it * 3).toByte() }

    private fun assertKeys(expected: Map<String, ByteArray>, actual: Map<String, ByteArray>?) {
        assertNotNull(actual)
        assertEquals(expected.keys, actual!!.keys)
        expected.forEach { (id, key) -> assertArrayEquals(id, key, actual[id]) }
    }

    @Test fun payloadRoundTripsEveryMac() {
        val keys = mapOf("mac-1" to a, "Mäc 2" to b, "empty" to ByteArray(0))
        assertKeys(keys, ShellVaultBlob.decode(ShellVaultBlob.encode(keys)))
        assertKeys(emptyMap(), ShellVaultBlob.decode(ShellVaultBlob.encode(emptyMap())))
    }

    @Test fun malformedPayloadsAreRejected() {
        val good = ShellVaultBlob.encode(mapOf("mac" to a))
        assertNull(ShellVaultBlob.decode(ByteArray(0)))
        assertNull("truncated", ShellVaultBlob.decode(good.copyOf(good.size - 1)))
        assertNull("trailing bytes", ShellVaultBlob.decode(good + 0))
        assertNull("other version", ShellVaultBlob.decode(byteArrayOf(2) + good.copyOfRange(1, good.size)))
        // Two entries for one Mac: not something the vault writes.
        val twice = byteArrayOf(1, 0, 2) + entry("mac", a) + entry("mac", b)
        assertNull(ShellVaultBlob.decode(twice))
    }

    @Test fun sealedBlobOpensOnlyWithItsDataKey() {
        val dataKey = ShellVaultBlob.newDataKey()
        val keys = mapOf("mac-1" to a, "mac-2" to b)
        val sealed = ShellVaultBlob.seal(dataKey, keys)
        assertKeys(keys, ShellVaultBlob.open(dataKey, sealed))
        assertNull(ShellVaultBlob.open(ShellVaultBlob.newDataKey(), sealed))
        val altered = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertNull(ShellVaultBlob.open(dataKey, altered))
        assertNull(ShellVaultBlob.open(dataKey, sealed.copyOf(ShellVaultBlob.IV_SIZE)))
        // A fresh IV each time: the same keys never seal to the same bytes.
        assertEquals(false, sealed.contentEquals(ShellVaultBlob.seal(dataKey, keys)))
    }

    @Test fun migrationMovesReadableEntriesAndMarksInvalidatedOnesLost() {
        val legacy = mapOf(
            "old" to ShellVaultBlob.LegacyRead.Key(a),
            "gone" to ShellVaultBlob.LegacyRead.Invalidated,
            "later" to ShellVaultBlob.LegacyRead.Retry,
        )
        val m = ShellVaultBlob.migrate(emptyMap(), legacy)
        assertKeys(mapOf("old" to a), m.keys)
        assertEquals(setOf("gone"), m.lost)
        // A Retry entry stays for the next unlock.
        assertEquals(setOf("old", "gone"), m.migrated)
    }

    @Test fun aKeyAlreadyInTheBlobWinsOverItsOlderEntry() {
        // The Mac granted again after the upgrade: its new key is in the blob, its old entry is stale.
        val m = ShellVaultBlob.migrate(mapOf("mac" to b), mapOf(
            "mac" to ShellVaultBlob.LegacyRead.Key(a),
            "other" to ShellVaultBlob.LegacyRead.Key(a),
        ))
        assertKeys(mapOf("mac" to b, "other" to a), m.keys)
        assertEquals(setOf("mac", "other"), m.migrated)
        assertEquals(emptySet<String>(), m.lost)
        // Not lost either: a newer key is there.
        val n = ShellVaultBlob.migrate(mapOf("mac" to b), mapOf("mac" to ShellVaultBlob.LegacyRead.Invalidated))
        assertEquals(emptySet<String>(), n.lost)
        assertKeys(mapOf("mac" to b), n.keys)
    }

    @Test fun migratedVaultSealsAndOpensAsOneBlob() {
        val dataKey = ShellVaultBlob.newDataKey()
        val m = ShellVaultBlob.migrate(emptyMap(), mapOf("m1" to ShellVaultBlob.LegacyRead.Key(a), "m2" to ShellVaultBlob.LegacyRead.Key(b)))
        assertKeys(mapOf("m1" to a, "m2" to b), ShellVaultBlob.open(dataKey, ShellVaultBlob.seal(dataKey, m.keys)))
    }

    private fun entry(id: String, key: ByteArray): ByteArray {
        val name = id.toByteArray()
        return byteArrayOf(0, name.size.toByte()) + name + byteArrayOf(0, key.size.toByte()) + key
    }
}
