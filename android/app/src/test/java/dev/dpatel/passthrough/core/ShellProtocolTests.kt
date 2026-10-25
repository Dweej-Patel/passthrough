package dev.dpatel.passthrough.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class ShellProtocolTests {
    private val shell get() = Fixtures.root["shell"]!!.jsonObject
    private fun b64(s: String) = Base64.getDecoder().decode(s)

    @Test fun constantsMatchFixtures() {
        assertEquals(shell["port"]!!.jsonPrimitive.int, RemoteShell.DEFAULT_PORT)
        assertEquals(shell["serviceType"]!!.jsonPrimitive.content, RemoteShell.SERVICE_TYPE)
        assertEquals(shell["proofLabel"]!!.jsonPrimitive.content, RemoteShell.PROOF_LABEL)
        assertEquals(shell["maxSessions"]!!.jsonPrimitive.int, RemoteShell.MAX_SESSIONS)
        assertEquals(shell["scrollbackBytes"]!!.jsonPrimitive.int, RemoteShell.SCROLLBACK_BYTES)
        assertEquals(shell["outputChunk"]!!.jsonPrimitive.int, RemoteShell.OUTPUT_CHUNK)
        assertEquals(shell["lineLimit"]!!.jsonPrimitive.int, RemoteShell.LINE_LIMIT)
    }

    @Test fun proofMatchesFixture() {
        for (p in shell["proofs"]!!.jsonArray.map { it.jsonObject }) {
            val key = b64(p["shellKey"]!!.jsonPrimitive.content)
            val nonce = b64(p["nonce"]!!.jsonPrimitive.content)
            val mac = b64(p["mac"]!!.jsonPrimitive.content)
            assertArrayEquals(mac, RemoteShell.proof(key, nonce))
            assertTrue(RemoteShell.proofIsValid(mac, key, nonce))
            assertFalse(RemoteShell.proofIsValid(mac, key, nonce.reversedArray()))
            assertFalse(RemoteShell.proofIsValid(mac.copyOf(mac.size - 1), key, nonce))
        }
    }

    @Test fun shellMessagesRoundTrip() {
        for (m in shell["messages"]!!.jsonArray) {
            val line = m.jsonObject["line"]!!.jsonPrimitive.content
            val encoded = String(ShellEnvelope.decode(line).encodeLine()).trimEnd('\n')
            assertEquals(line, Fixtures.normalize(Json.parseToJsonElement(line)), Fixtures.normalize(Json.parseToJsonElement(encoded)))
        }
    }

    /** The Mac's state and a phone's requests to change it; absent fields stay absent. */
    @Test fun macStateAndControlFields() {
        val lines = shell["messages"]!!.jsonArray.map { ShellEnvelope.decode(it.jsonObject["line"]!!.jsonPrimitive.content) }
        val states = lines.filter { it.t == ShellEnvelope.MAC_STATE }.mapNotNull { it.state }
        assertEquals(
            MacState(awake = true, battery = 0.64, charging = false, minutesLeft = 190, batteryFloor = 0.2, hot = false,
                vpn = "on", vpnName = "NordVPN Germany", killSwitch = true, control = true, internet = true),
            states.first(),
        )
        assertEquals(MacState(awake = false, awakeStopped = "battery", battery = 0.19, charging = false, batteryFloor = 0.2, control = false), states.last())
        assertEquals(false, lines.first { it.t == ShellEnvelope.SET_AWAKE }.on)
        assertEquals(true, lines.first { it.t == ShellEnvelope.SET_VPN }.on)
        assertTrue(lines.any { it.t == ShellEnvelope.ERROR && it.reason == ShellError.NOT_ALLOWED.wire })
    }

    /** A replay's sizes: the entry's starting size, and a size on the transcript line it applies from. */
    @Test fun replaySizeFields() {
        val lines = shell["messages"]!!.jsonArray.map { ShellEnvelope.decode(it.jsonObject["line"]!!.jsonPrimitive.content) }
        val entry = lines.filter { it.t == ShellEnvelope.HISTORY_LIST }.flatMap { it.history.orEmpty() }.first { it.cols != null }
        assertEquals(48, entry.cols)
        assertEquals(20, entry.rows)
        val pieces = lines.filter { it.t == ShellEnvelope.TRANSCRIPT_DATA }
        assertTrue(pieces.any { it.cols == null && it.rows == null })   // an older Mac's: just output
        val collector = ShellReplay.Collector()
        for (p in pieces.filter { it.cols != null }) collector.add(b64(p.data!!), p.cols, p.rows)
        assertEquals(
            listOf(ShellReplayChunk.Resize(48, 20), ShellReplayChunk.Output(b64("JCBscw0K")), ShellReplayChunk.Resize(100, 30)),
            collector.chunks(),
        )
    }

    @Test fun replayCollectorAndFit() {
        val c = ShellReplay.Collector()
        c.add("a".toByteArray())
        c.add("b".toByteArray(), 0, 5)   // invalid: ignored
        c.add("c".toByteArray(), 48, 20)
        c.add("d".toByteArray())
        c.add(ByteArray(0), 100, 30)
        assertEquals(
            listOf(ShellReplayChunk.Output("ab".toByteArray()), ShellReplayChunk.Resize(48, 20), ShellReplayChunk.Output("cd".toByteArray()), ShellReplayChunk.Resize(100, 30)),
            c.chunks(),
        )
        assertEquals(100 to 30, ShellReplay.largestGrid(c.chunks()))
        assertEquals(null, ShellReplay.largestGrid(listOf(ShellReplayChunk.Output("x".toByteArray()))))
        assertFalse(ShellReplay.isValid(1001, 5))
        assertEquals(1f, ShellReplay.fitScale(300f, 300f, 600f, 600f, 0.5f))
        assertEquals(0.75f, ShellReplay.fitScale(800f, 300f, 600f, 600f, 0.5f))
        assertEquals(0.5f, ShellReplay.fitScale(6000f, 300f, 600f, 600f, 0.5f))
    }

    @Test fun helloAndMacInfoFields() {
        val lines = shell["messages"]!!.jsonArray.map { it.jsonObject["line"]!!.jsonPrimitive.content }
        assertEquals(ShellEnvelope.HELLO, ShellEnvelope.decode(lines.first { "\"hello\"" in it }).t)
        val info = ShellEnvelope.decode(lines.first { "\"macInfo\"" in it })
        assertEquals(ShellEnvelope.MAC_INFO, info.t)
        assertTrue(IrohInfo.isValidID(info.irohID!!))
        assertEquals("https://relay.example.com/", info.irohRelay)
        assertEquals("relay-token-123", info.relayToken)
        assertEquals(listOf("192.168.1.20", "100.101.102.103"), info.addresses)
    }

    @Test fun irohValidation() {
        val id = "ab".repeat(32)
        assertTrue(IrohInfo.isValidID(id))
        assertFalse(IrohInfo.isValidID(id.dropLast(1)))
        assertFalse(IrohInfo.isValidID(id.uppercase()))
        assertFalse(IrohInfo.isValidID("g" + id.drop(1)))
        assertTrue(IrohInfo.isValidRelay("https://relay.example.com/"))
        assertFalse(IrohInfo.isValidRelay("http://relay.example.com/"))
        assertFalse(IrohInfo.isValidRelay("https://"))
        assertFalse(IrohInfo.isValidRelay("https://a.example.com/" + "x".repeat(256)))
        assertTrue(IrohInfo.isValidToken("t".repeat(512)))
        assertFalse(IrohInfo.isValidToken("t".repeat(513)))
        assertTrue(IrohInfo.isValidToken("é".repeat(256)))
        assertFalse(IrohInfo.isValidToken("é".repeat(257)))
        assertFalse(IrohInfo.areValid(null, "https://r.example.com/", "t"))
    }

    @Test fun addressPolicy() {
        for (a in shell["addresses"]!!.jsonArray.map { it.jsonObject }) {
            val host = a["host"]!!.jsonPrimitive.content
            assertEquals(host, a["allowed"]!!.jsonPrimitive.boolean, ShellAddressPolicy.isAllowed(host))
        }
        assertFalse(ShellAddressPolicy.isAllowed("localhost"))
        assertFalse(ShellAddressPolicy.isAllowed("example.com"))
        assertTrue(ShellAddressPolicy.isAllowed("127.0.0.1"))
        assertTrue(ShellAddressPolicy.isAllowed("::1"))
        assertTrue(ShellAddressPolicy.isAllowed("fd00::1"))
    }

    @Test fun advertisableOrdersTailscaleLast() {
        val input = listOf("100.101.102.103", "127.0.0.1", "fe80::1%en0", "192.168.1.20", "8.8.8.8", "fd7a:115c:a1e0::1",
            "192.168.1.20", "fd00::1", "10.0.0.5")
        assertEquals(listOf("192.168.1.20", "fd00::1", "10.0.0.5", "100.101.102.103", "fd7a:115c:a1e0::1"), ShellAddressPolicy.advertisable(input))
    }
}
