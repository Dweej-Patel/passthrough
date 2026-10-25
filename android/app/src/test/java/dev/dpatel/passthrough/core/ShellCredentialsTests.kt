package dev.dpatel.passthrough.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors PassthroughCoreTests/ShellCredentialsTests.swift. */
class ShellCredentialsTests {
    private fun client(id: String, shell: ShellGrant?) = PairedClient(id, id, "", 0L, shell = shell)

    private val grant = ShellGrant(certSHA256 = "ab", port = 7022, addresses = listOf("192.168.1.2", "100.64.0.1"), macName = "Studio")

    @Test fun buildsOnlyForGrantedMacsWithKeys() {
        val clients = listOf(client("a", grant), client("b", null), client("c", grant))
        val creds = ShellCredentials.build(clients, "phone", key = { if (it == "a") byteArrayOf(1) else null }, manualAddress = { null })
        assertEquals(
            listOf(ShellCredential("a", "Studio", "ab", byteArrayOf(1), "phone", 7022, listOf("192.168.1.2", "100.64.0.1"))),
            creds,
        )
    }

    @Test fun carriesIrohDetailsAndRedactsToken() {
        val id = "ab".repeat(32)
        val iroh = ShellGrant("ab", 7022, emptyList(), "Studio", id, "https://r.example.com/")
        val creds = ShellCredentials.build(listOf(client("a", iroh), client("b", grant)), "phone", key = { byteArrayOf(1) }, manualAddress = { null }, relayToken = { "tok-secret" })
        assertEquals(id, creds[0].irohID)
        assertEquals("https://r.example.com/", creds[0].irohRelay)
        assertEquals("tok-secret", creds[0].relayToken)
        assertNull(creds[1].irohID)
        assertNull(creds[1].relayToken)
        assertEquals(creds[0], creds[0].copy())
        assertNotEquals(creds[0], creds[0].copy(relayToken = "other"))
        assertFalse(creds[0].toString().contains("tok-secret"))
    }

    @Test fun manualAddressComesFirstWithoutRepeats() {
        assertEquals(listOf("100.64.0.1", "10.0.0.2"), ShellCredentials.addresses(listOf("10.0.0.2", "100.64.0.1"), " 100.64.0.1 "))
        assertEquals(listOf("studio.tailnet.ts.net", "10.0.0.2"), ShellCredentials.addresses(listOf("10.0.0.2"), "studio.tailnet.ts.net"))
        assertEquals(listOf("10.0.0.2"), ShellCredentials.addresses(listOf("10.0.0.2"), "   "))
        assertEquals(listOf("10.0.0.2"), ShellCredentials.addresses(listOf("10.0.0.2"), null))
    }

    private fun service(name: String) = ShellService(name, "192.168.1.9", RemoteShell.DEFAULT_PORT)

    @Test fun discoveredPrefersTheMacsName() {
        val results = listOf(service("Other"), service("Studio"))
        assertEquals(service("Studio"), ShellCredentials.discovered(results, macName = "Studio", shellMacCount = 2))
    }

    @Test fun discoveredFallsBackOnlyWhenUnambiguous() {
        assertEquals(service("Studio (2)"), ShellCredentials.discovered(listOf(service("Studio (2)")), "Studio", 1))
        assertNull(ShellCredentials.discovered(listOf(service("Studio (2)")), "Studio", 2))
        assertNull(ShellCredentials.discovered(listOf(service("A"), service("B")), "Studio", 1))
        assertNull(ShellCredentials.discovered(emptyList(), "Studio", 1))
    }

    @Test fun unresolvedServiceHasNoEndpoint() {
        assertNull(ShellService("Studio", null, 0).endpoint)
        assertEquals("192.168.1.9" to 7893, service("Studio").endpoint)
    }

    @Test fun serviceNamesAreUnescaped() {
        assertEquals("Jane’s MacBook Pro", ShellCredentials.unescapeServiceName("Jane\\226\\128\\153s\\032MacBook\\032Pro"))
        assertEquals("a.b\\c", ShellCredentials.unescapeServiceName("a\\.b\\\\c"))
        assertEquals("Studio", ShellCredentials.unescapeServiceName("Studio"))
    }

    @Test fun keyStatusCopy() {
        assertEquals("Set a device passcode to use Remote shell.", ShellKeyStatus.NEEDS_PASSCODE.message)
        assertEquals("Couldn't read the Remote shell key. Plug into the Mac again to renew access.", ShellKeyStatus.KEY_UNAVAILABLE.message)
        assertEquals("Unlock Passthrough to use Remote shell.", ShellKeyStatus.LOCKED.message)
        assertNull(ShellKeyStatus.READY.message)
    }

    // MARK: macInfo

    private val irohID = "cd".repeat(32)

    private fun grantedRegistry(): PairingRegistry {
        val reg = PairingRegistry(MemoryStore(), secrets = MemorySecrets()).apply { withSealing() }
        reg.pair(reg.issueCode().code, "mac1", "Studio")
        reg.grantShell("mac1", grant, ByteArray(32) { 7 })
        return reg
    }

    @Test fun macInfoIsKeptWithTheGrantAndUsedFromTheNextConnect() {
        val reg = grantedRegistry()
        val key = ByteArray(32) { 9 }
        val before = ShellCredentials.build(reg.clients, "phone", key = { key }, manualAddress = { "studio.ts.net" }, relayToken = reg::relayToken).single()
        val info = ShellEvent.MacInfo(irohID, "https://relay.example.com/", "tok-secret", listOf("192.168.1.50"))
        val after = ShellCredentials.applyMacInfo(reg, before, info, manualAddress = "studio.ts.net")!!
        assertEquals(listOf("studio.ts.net", "192.168.1.50"), after.addresses)
        assertEquals(irohID, after.irohID)
        assertEquals("https://relay.example.com/", after.irohRelay)
        assertEquals("tok-secret", after.relayToken)
        assertEquals("the shell key and pin are untouched", before.copy(addresses = after.addresses, irohID = irohID,
            irohRelay = "https://relay.example.com/", relayToken = "tok-secret"), after)
        // What the next refresh builds from the registry is the same credential.
        assertEquals(after, ShellCredentials.build(reg.clients, "phone", key = { key }, manualAddress = { "studio.ts.net" }, relayToken = reg::relayToken).single())
        assertTrue("only dialling details changed: the live connection is kept", ShellCredentials.sameKey(before, after))
        assertFalse(ShellCredentials.sameKey(before, before.copy(shellKey = ByteArray(32))))
        assertFalse(ShellCredentials.sameKey(before, before.copy(certSHA256 = "ff")))

        // The Mac turned its built-in path off: the details and token go.
        val off = ShellCredentials.applyMacInfo(reg, after, ShellEvent.MacInfo(null, null, null, null), manualAddress = null)!!
        assertNull(off.irohID)
        assertNull(off.irohRelay)
        assertNull(off.relayToken)
        assertEquals("absent addresses keep the stored ones", listOf("192.168.1.50"), off.addresses)
    }

    @Test fun macInfoWithoutAGrantChangesNothing() {
        val reg = PairingRegistry(MemoryStore(), secrets = MemorySecrets())
        val cred = ShellCredential("mac1", "Studio", "ab", byteArrayOf(1), "phone", 7022, emptyList())
        assertNull(ShellCredentials.applyMacInfo(reg, cred, ShellEvent.MacInfo(irohID, null, null, listOf("10.0.0.1")), null))
    }
}
