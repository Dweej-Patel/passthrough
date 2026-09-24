package dev.dpatel.passthrough.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.io.StringReader

/**
 * Checks this app against protocol/fixtures.json, the same file the Swift
 * tests read, so the phone and Mac sides can't drift apart.
 */
class ProtocolFixtureTests {
    private val fixtures: JsonObject by lazy {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "protocol/fixtures.json").exists()) dir = dir.parentFile
        val file = File(requireNotNull(dir) { "protocol/fixtures.json not found above ${File("").absolutePath}" }, "protocol/fixtures.json")
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    @Test fun constantsMatch() {
        assertEquals(fixtures["protocolVersion"]!!.jsonPrimitive.int, PassthroughProtocol.VERSION)
        val ports = fixtures["ports"]!!.jsonObject
        assertEquals(ports["socks"]!!.jsonPrimitive.int, PassthroughProtocol.DEFAULT_SOCKS_PORT)
        assertEquals(ports["control"]!!.jsonPrimitive.int, PassthroughProtocol.DEFAULT_CONTROL_PORT)
        assertEquals(fixtures["pairingCodeLifetimeSeconds"]!!.jsonPrimitive.long * 1000, PassthroughProtocol.PAIRING_CODE_LIFETIME_MS)
        assertEquals(fixtures["pairingFailures"]!!.jsonArray.map { it.jsonPrimitive.content }, PairingFailure.entries.map { it.wire })
    }

    @Test fun tokensHashAndValidateAlike() {
        for (t in fixtures["tokens"]!!.jsonArray.map { it.jsonObject }) {
            val token = t["token"]!!.jsonPrimitive.content
            assertEquals(token, t["sha256"]!!.jsonPrimitive.content, PairingToken.hash(token))
            assertEquals(token, t["wellFormed"]!!.jsonPrimitive.boolean, PairingToken.isWellFormed(token))
        }
    }

    /** Every field survives a decode and re-encode, and nothing extra (like nulls) is added. */
    @Test fun messagesRoundTrip() {
        for (m in fixtures["messages"]!!.jsonArray) {
            val line = m.jsonObject["line"]!!.jsonPrimitive.content
            val decoded = LineReader(line.plus("\n").byteInputStream()).next()!!.let(ControlEnvelope::decode)
            val encoded = String(decoded.encodeLine()).trimEnd('\n')
            assertEquals(line, normalize(Json.parseToJsonElement(line)), normalize(Json.parseToJsonElement(encoded)))
        }
    }

    @Test fun formatsMatch() {
        for (r in fixtures["rates"]!!.jsonArray.map { it.jsonObject }) {
            val expected = r["value"]!!.jsonPrimitive.content to r["unit"]!!.jsonPrimitive.content
            assertEquals(expected, ByteFormat.rate(r["bytesPerSecond"]!!.jsonPrimitive.double))
        }
        for (d in fixtures["durations"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(d["text"]!!.jsonPrimitive.content, ByteFormat.duration(d["seconds"]!!.jsonPrimitive.long))
        }
    }

    @Test fun lineReaderSkipsBlankLinesAndCapsLength() {
        val reader = LineReader(StringReader("a\n\nb\n").readText().byteInputStream())
        assertEquals("a", reader.next())
        assertEquals("b", reader.next())
        assertEquals(null, reader.next())
        val long = LineReader("123456789".byteInputStream(), limit = 8)
        assertEquals(true, runCatching { long.next() }.isFailure)
    }

    @Test fun dnsRedirectRules() {
        val f = fixtures["dnsRedirect"]!!.jsonObject
        assertEquals(f["port"]!!.jsonPrimitive.int, DnsRedirect.PORT)
        assertEquals(f["fallback"]!!.jsonPrimitive.content, DnsRedirect.FALLBACK)
        for (d in f["destinations"]!!.jsonArray.map { it.jsonObject }) {
            val ip = java.net.InetAddress.getByName(d["address"]!!.jsonPrimitive.content)
            val address = Socks5.Address.parse(Socks5.rawAddress(ip, d["port"]!!.jsonPrimitive.int))!!
            assertEquals(address.toString(), d["redirect"]!!.jsonPrimitive.boolean, DnsRedirect.applies(address))
        }
        for (c in f["serverChoice"]!!.jsonArray.map { it.jsonObject }) {
            val system = c["system"]!!.jsonArray.map { java.net.InetAddress.getByName(it.jsonPrimitive.content) }
            assertEquals(java.net.InetAddress.getByName(c["chosen"]!!.jsonPrimitive.content), DnsRedirect.server(system))
        }
    }

    /** Numbers compare by value (1.0 == 1, 1.7580624E9 == 1758062400.0); strings and booleans by content. */
    private fun normalize(e: JsonElement): Any? = when (e) {
        is JsonObject -> e.mapValues { normalize(it.value) }
        is JsonArray -> e.map { normalize(it) }
        is JsonPrimitive -> if (e.isString) e.content else e.content.toBooleanStrictOrNull() ?: e.content.toDoubleOrNull()
    }
}
