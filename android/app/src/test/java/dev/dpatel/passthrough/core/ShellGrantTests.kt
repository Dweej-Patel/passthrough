package dev.dpatel.passthrough.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.net.InetAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.Base64

class ShellGrantTests {
    private val store = MemoryStore()
    private val secrets = MemorySecrets()
    private val registry = PairingRegistry(store, secrets = secrets)
    private val control = ControlServer(0, 7890, registry, ByteCounter()) { DeviceStatus("Pixel", "5G", "Carrier", 0.8, "background") }
    private val cert = "b".repeat(64)
    private var socket: Socket? = null
    private lateinit var reader: BufferedReader

    private fun connect() {
        control.start()
        socket = Socket(InetAddress.getLoopbackAddress(), control.boundPort).apply { soTimeout = 3000 }
        reader = socket!!.getInputStream().bufferedReader()
    }

    @After fun tearDown() { socket?.close(); control.stop() }

    private fun send(m: ControlEnvelope) = socket!!.getOutputStream().write(m.encodeLine())
    private fun receive() = ControlEnvelope.decode(reader.readLine())
    private fun key(n: Int = 32) = ByteArray(n).also { SecureRandom().nextBytes(it) }
    private fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)

    private fun hello() {
        connect()
        send(ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 1, clientID = "mac1", name = "MacBook"))
        assertEquals(ControlEnvelope.WELCOME, receive().t)
    }

    private fun pair() {
        hello()
        send(ControlEnvelope(ControlEnvelope.PAIR, clientID = "mac1", name = "MacBook", code = registry.issueCode().code))
        assertEquals(ControlEnvelope.PAIRED, receive().t)
        assertEquals(ControlEnvelope.STATUS, receive().t)
    }

    private fun grant(key: ByteArray = key(), cert: String = this.cert, port: Int = 7893, addresses: List<String>? = listOf("192.168.1.5", "fe80::1"), macName: String? = "MacBook") =
        send(ControlEnvelope(ControlEnvelope.SHELL_GRANT, shellKey = b64(key), certSHA256 = cert, shellPort = port, addresses = addresses, macName = macName))

    private val irohID = "3f".repeat(32)

    private fun grantIroh(id: String? = irohID, relay: String? = "https://relay.example.com/", token: String? = "tok-secret") =
        send(ControlEnvelope(ControlEnvelope.SHELL_GRANT, shellKey = b64(key()), certSHA256 = cert, shellPort = 7893, addresses = listOf("192.168.1.5"),
            macName = "MacBook", irohID = id, irohRelay = relay, relayToken = token))

    /** A ping round trip: everything sent before it has been handled. */
    private fun sync() {
        send(ControlEnvelope(ControlEnvelope.PING))
        var m = receive()
        while (m.t != ControlEnvelope.PONG) m = receive()
    }

    @Test fun pairThenGrant() {
        pair()
        val k = key()
        grant(k)
        var reply = receive()
        while (reply.t == ControlEnvelope.STATUS) reply = receive()
        assertEquals(ControlEnvelope.SHELL_GRANTED, reply.t)
        assertEquals(registry.phoneID, reply.phoneID)
        assertNull("no grant ID sent, none echoed", reply.grantID)
        assertArrayEquals(k, registry.pendingShellKey("mac1"))
        assertEquals(ShellGrant(cert, 7893, listOf("192.168.1.5", "fe80::1"), "MacBook"), registry.clients.first().shell)
        registry.clearPendingShellKey("mac1")
        assertNull(registry.pendingShellKey("mac1"))
    }

    private fun grantedReply(): ControlEnvelope {
        var reply = receive()
        while (reply.t == ControlEnvelope.STATUS) reply = receive()
        assertEquals(ControlEnvelope.SHELL_GRANTED, reply.t)
        return reply
    }

    @Test fun grantIDIsEchoed() {
        pair()
        val id = "g".repeat(ControlEnvelope.MAX_GRANT_ID_LENGTH)
        send(ControlEnvelope(ControlEnvelope.SHELL_GRANT, shellKey = b64(key()), certSHA256 = cert, shellPort = 7893, macName = "M", grantID = id))
        assertEquals(id, grantedReply().grantID)
    }

    @Test fun overlongGrantIDIsNotEchoed() {
        pair()
        val id = "g".repeat(ControlEnvelope.MAX_GRANT_ID_LENGTH + 1)
        send(ControlEnvelope(ControlEnvelope.SHELL_GRANT, shellKey = b64(key()), certSHA256 = cert, shellPort = 7893, macName = "M", grantID = id))
        assertNull("the grant is stored; the bad ID is not echoed", grantedReply().grantID)
        assertNotNull(registry.pendingShellKey("mac1"))
    }

    @Test fun grantWithIrohFieldsStoresTokenAsSecret() {
        pair()
        grantIroh()
        sync()
        assertEquals(ShellGrant(cert, 7893, listOf("192.168.1.5"), "MacBook", irohID, "https://relay.example.com/"), registry.clients.first().shell)
        assertEquals("tok-secret", registry.relayToken("mac1"))
        assertFalse(store.getString(PairingRegistry.CLIENTS_KEY)!!.contains("tok-secret"))
    }

    @Test fun invalidIrohFieldsDropOnlyTheIrohInfo() {
        pair()
        grantIroh(relay = "http://relay.example.com/")
        sync()
        assertEquals(ShellGrant(cert, 7893, listOf("192.168.1.5"), "MacBook"), registry.clients.first().shell)
        assertNotNull(registry.pendingShellKey("mac1"))
        assertNull(registry.relayToken("mac1"))
    }

    @Test fun oldGrantJsonDecodes() {
        val s = MemoryStore()
        s.putString(PairingRegistry.CLIENTS_KEY, """[{"id":"mac1","name":"M","tokenHash":"h","pairedAt":0,"shell":{"certSHA256":"bb","port":7893,"addresses":["10.0.0.1"],"macName":"Old"}}]""")
        val g = PairingRegistry(s).clients.single().shell!!
        assertNull(g.irohID)
        assertNull(g.irohRelay)
        assertEquals("Old", g.macName)
    }

    @Test fun updateShellInfoKeepsKeyAndCert() {
        val reg = PairingRegistry(MemoryStore(), secrets = secrets)
        val code = reg.issueCode().code
        reg.pair(code, "mac1", "M")
        assertFalse(reg.updateShellInfo("mac1", irohID, null, null, null))
        val k = key()
        assertTrue(reg.grantShell("mac1", ShellGrant(cert, 7893, listOf("10.0.0.1"), "M"), k))
        assertTrue(reg.updateShellInfo("mac1", irohID, "https://r.example.com/", "tk", (0 until 20).map { "10.0.0.$it" }))
        var g = reg.clients.first().shell!!
        assertEquals(irohID, g.irohID)
        assertEquals("https://r.example.com/", g.irohRelay)
        assertEquals(16, g.addresses.size)
        assertEquals(cert, g.certSHA256)
        assertArrayEquals(k, reg.pendingShellKey("mac1"))
        assertEquals("tk", reg.relayToken("mac1"))

        // Invalid iroh details change nothing about the stored ones, but valid addresses still apply.
        assertTrue(reg.updateShellInfo("mac1", "nope", null, "x", listOf("10.9.9.9")))
        assertEquals("tk", reg.relayToken("mac1"))
        assertEquals(irohID, reg.clients.first().shell!!.irohID)
        assertEquals(listOf("10.9.9.9"), reg.clients.first().shell!!.addresses)
        // An absent token clears the stored one; absent addresses keep them.
        assertTrue(reg.updateShellInfo("mac1", irohID, null, null, null))
        g = reg.clients.first().shell!!
        assertNull(g.irohRelay)
        assertEquals(listOf("10.9.9.9"), g.addresses)
        assertNull(reg.relayToken("mac1"))
        // No id: the Mac has no iroh; stored details go and a token alone is never stored.
        assertTrue(reg.updateShellInfo("mac1", irohID, "https://r.example.com/", "tk", null))
        assertTrue(reg.updateShellInfo("mac1", null, "https://r.example.com/", "tk", null))
        assertNull(reg.clients.first().shell!!.irohID)
        assertNull(reg.clients.first().shell!!.irohRelay)
        assertNull(reg.relayToken("mac1"))

        assertTrue(reg.updateShellInfo("mac1", irohID, null, "tk2", null))
        reg.revoke("mac1")
        assertNull(secrets.read("shell.relayToken.mac1"))
    }

    @Test fun revokeAllDeletesRelayTokens() {
        val reg = PairingRegistry(MemoryStore(), secrets = secrets)
        for (id in listOf("a", "b")) {
            reg.pair(reg.issueCode().code, id, id)
            assertTrue(reg.grantShell(id, ShellGrant(cert, 7893, emptyList(), id, irohID), key(), "tok-$id"))
        }
        assertEquals("tok-a", reg.relayToken("a"))
        reg.revokeAll()
        assertNull(secrets.read("shell.relayToken.a"))
        assertNull(secrets.read("shell.relayToken.b"))
    }

    @Test fun grantNormalisesAndCaps() {
        pair()
        grant(cert = "ABCDEF" + "0".repeat(58), addresses = (1..20).map { "10.0.0.$it" }, macName = null)
        sync()
        val g = registry.clients.first().shell!!
        assertEquals("abcdef" + "0".repeat(58), g.certSHA256)
        assertEquals(16, g.addresses.size)
        assertEquals("MacBook", g.macName)
        grant(macName = "m".repeat(100))
        sync()
        assertEquals(64, registry.clients.first().shell!!.macName.length)
    }

    @Test fun grantRequiresAuthentication() {
        hello()
        grant()
        sync()
        assertNull(registry.pendingShellKey("mac1"))
        assertTrue(registry.clients.isEmpty())
    }

    @Test fun badKeyIsIgnored() {
        pair()
        grant(key = key(16))
        grant(cert = "zz" + "b".repeat(62))
        grant(port = 0)
        grant(port = 65536)
        sync()
        assertNull(registry.pendingShellKey("mac1"))
        assertNull(registry.clients.first().shell)
        // The channel survived: a valid grant still works.
        grant()
        var reply = receive()
        while (reply.t == ControlEnvelope.STATUS) reply = receive()
        assertEquals(ControlEnvelope.SHELL_GRANTED, reply.t)
    }

    @Test fun revokeDeletesShellGrant() {
        val reg = PairingRegistry(MemoryStore(), secrets = secrets)
        for (id in listOf("mac1", "mac2")) {
            val code = reg.issueCode().code
            assertTrue(reg.pair(code, id, id) is PairingRegistry.PairResult.Success)
            assertTrue(reg.grantShell(id, ShellGrant(cert, 7893, emptyList(), id), key()))
        }
        assertFalse(reg.grantShell("unknown", ShellGrant(cert, 7893, emptyList(), "x"), key()))
        assertNull(secrets.read("shell.pending.unknown"))
        reg.revoke("mac1")
        assertNull(reg.pendingShellKey("mac1"))
        assertNotNull(reg.pendingShellKey("mac2"))
        reg.revokeAll()
        assertNull(reg.pendingShellKey("mac2"))
        assertTrue(reg.clients.isEmpty())
    }

    @Test fun storageFailureDoesNotRecordGrant() {
        val refusing = object : SecretStore {
            override fun read(account: String): ByteArray? = null
            override fun write(account: String, data: ByteArray) = false
            override fun delete(account: String) {}
        }
        val reg = PairingRegistry(MemoryStore(), secrets = refusing)
        assertTrue(reg.pair(reg.issueCode().code, "mac1", "M") is PairingRegistry.PairResult.Success)
        assertFalse(reg.grantShell("mac1", ShellGrant(cert, 7893, emptyList(), "M"), key()))
        assertNull(reg.clients.first().shell)
    }

    @Test fun phoneIDIsStable() {
        val s = MemoryStore()
        val first = PairingRegistry(s).phoneID
        assertEquals(first, PairingRegistry(s).phoneID)
        assertNotEquals(first, PairingRegistry(MemoryStore()).phoneID)
    }

    /** Paired Macs saved before shell grants existed must still load. */
    @Test fun oldPairedClientStillDecodes() {
        val s = MemoryStore()
        s.putString(PairingRegistry.CLIENTS_KEY, """[{"id":"mac1","name":"M","tokenHash":"h","pairedAt":0}]""")
        val c = PairingRegistry(s).clients.single()
        assertEquals("mac1", c.id)
        assertNull(c.shell)
    }
}
