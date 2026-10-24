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
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.StringReader

/**
 * Checks this app against protocol/fixtures.json, the same file the Swift
 * tests read, so the phone and Mac sides can't drift apart.
 */
class ProtocolFixtureTests {
    private val fixtures: JsonObject get() = Fixtures.root

    @Test fun constantsMatch() {
        assertEquals(fixtures["protocolVersion"]!!.jsonPrimitive.int, PassthroughProtocol.VERSION)
        val ports = fixtures["ports"]!!.jsonObject
        assertEquals(ports["socks"]!!.jsonPrimitive.int, PassthroughProtocol.DEFAULT_SOCKS_PORT)
        assertEquals(ports["control"]!!.jsonPrimitive.int, PassthroughProtocol.DEFAULT_CONTROL_PORT)
        assertEquals(fixtures["pairingCodeLifetimeSeconds"]!!.jsonPrimitive.long * 1000, PassthroughProtocol.PAIRING_CODE_LIFETIME_MS)
        assertEquals(fixtures["pairingMaxAttempts"]!!.jsonPrimitive.int, PassthroughProtocol.PAIRING_MAX_ATTEMPTS)
        assertEquals(fixtures["pairingLockoutSeconds"]!!.jsonPrimitive.long * 1000, PassthroughProtocol.PAIRING_LOCKOUT_MS)
        assertEquals(fixtures["unauthenticatedTimeoutSeconds"]!!.jsonPrimitive.long * 1000, PassthroughProtocol.UNAUTHENTICATED_TIMEOUT_MS)
        assertEquals(fixtures["pairingFailures"]!!.jsonArray.map { it.jsonPrimitive.content }, PairingFailure.entries.map { it.wire })
    }

    @Test fun tokensHashAndValidateAlike() {
        for (t in fixtures["tokens"]!!.jsonArray.map { it.jsonObject }) {
            val token = t["token"]!!.jsonPrimitive.content
            assertEquals(token, t["sha256"]!!.jsonPrimitive.content, PairingToken.hash(token))
            assertEquals(token, t["wellFormed"]!!.jsonPrimitive.boolean, PairingToken.isWellFormed(token))
        }
    }

    /** The same proofs and SOCKS5 password as the Swift side computes, from the same vectors. */
    @Test fun controlAuthVectors() {
        val f = fixtures["controlAuth"]!!.jsonObject
        assertEquals(f["phoneLabel"]!!.jsonPrimitive.content, ControlAuth.PHONE_LABEL)
        assertEquals(f["macLabel"]!!.jsonPrimitive.content, ControlAuth.MAC_LABEL)
        assertEquals(f["socksLabel"]!!.jsonPrimitive.content, ControlAuth.SOCKS_LABEL)
        assertEquals(f["nonceLength"]!!.jsonPrimitive.int, ControlAuth.NONCE_LENGTH)
        val b64 = java.util.Base64.getEncoder()
        for (v in f["vectors"]!!.jsonArray.map { it.jsonObject }) {
            fun s(k: String) = v[k]!!.jsonPrimitive.content
            val token = s("token")
            val clientID = s("clientID")
            val macNonce = ControlAuth.decodeNonce(s("macNonce"))!!
            val phoneNonce = ControlAuth.decodeNonce(s("phoneNonce"))!!
            assertEquals(s("tokenSHA256"), PairingToken.hash(token))
            // The Mac's K (from the token) and the phone's (from the hash it keeps) agree.
            val phoneKey = ControlAuth.keyFromHash(s("tokenSHA256"))!!
            assertArrayEquals(ControlAuth.key(token), phoneKey)
            assertEquals(s("phoneProof"), b64.encodeToString(ControlAuth.phoneProof(phoneKey, clientID, macNonce, phoneNonce)))
            assertEquals(s("macProof"), b64.encodeToString(ControlAuth.macProof(ControlAuth.key(token), clientID, macNonce, phoneNonce)))
            assertTrue(ControlAuth.isValidMacProof(s("macProof"), phoneKey, clientID, macNonce, phoneNonce))
            // Bound to its own label, the nonces' order and the client ID.
            assertFalse(ControlAuth.isValidMacProof(s("phoneProof"), phoneKey, clientID, macNonce, phoneNonce))
            assertFalse(ControlAuth.isValidMacProof(s("macProof"), phoneKey, clientID, phoneNonce, macNonce))
            assertFalse(ControlAuth.isValidMacProof(s("macProof"), phoneKey, clientID + "x", macNonce, phoneNonce))
            assertEquals(s("socksPassword"), ControlAuth.socksPassword(phoneKey))
            assertTrue("the password has a token's shape", PairingToken.isWellFormed(ControlAuth.socksPassword(phoneKey)))
        }
        assertNull(ControlAuth.keyFromHash("zz"))
        assertNull(ControlAuth.keyFromHash("g".repeat(64)))
        assertNull(ControlAuth.decodeNonce(java.util.Base64.getEncoder().encodeToString(ByteArray(31))))
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

    /** Sealed by the Swift implementation: the Android one opens it, byte for byte the same format. */
    @Test fun shellKeySealVector() {
        val f = fixtures["shellKeySeal"]!!.jsonObject
        fun hex(name: String) = f[name]!!.jsonPrimitive.content.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val recipientPrivate = ShellKeySeal.privateKeyFromScalar(hex("recipientPrivateKey"))
        val recipientPublic = ShellKeySeal.publicKey(hex("recipientPublicKey"))!!
        val clientID = f["clientID"]!!.jsonPrimitive.content
        org.junit.Assert.assertArrayEquals(hex("key"), ShellKeySeal.open(hex("sealed"), clientID, recipientPrivate, recipientPublic))
    }

    @Test fun localDestinations() {
        val f = fixtures["localDestinations"]!!.jsonObject
        for (d in f["addresses"]!!.jsonArray.map { it.jsonObject }) {
            val text = d["ip"]!!.jsonPrimitive.content
            val local = d["local"]!!.jsonPrimitive.boolean
            // The JDK parses literals without a lookup; this checks ipLiteral against it too.
            val ip = java.net.InetAddress.getByName(text)
            assertEquals(text, ip, Socks5.Address.ipLiteral(text))
            val raw = byteArrayOf((if (ip.address.size == 4) Socks5.AddressType.IPV4 else Socks5.AddressType.IPV6).toByte()) + ip.address + byteArrayOf(1, 187.toByte())
            assertEquals(text, local, Socks5.Address.parse(raw)!!.isLocalOnly)
            assertEquals("$text as a name", local, Socks5.Address.parse(Socks5.Address.domain(text, 443))!!.isLocalOnly)
            assertEquals("$text resolved", local, Socks5.Address.isLocalIp(ip))
        }
        for (d in f["names"]!!.jsonArray.map { it.jsonObject }) {
            val text = d["name"]!!.jsonPrimitive.content
            assertEquals(text, d["local"]!!.jsonPrimitive.boolean, Socks5.Address.parse(Socks5.Address.domain(text, 443))!!.isLocalOnly)
        }
    }

    private fun normalize(e: JsonElement): Any? = Fixtures.normalize(e)
}
