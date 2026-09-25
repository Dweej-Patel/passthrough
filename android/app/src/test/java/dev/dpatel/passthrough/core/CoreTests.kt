package dev.dpatel.passthrough.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.DataInputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

private fun Socket.io() = DataInputStream(getInputStream()) to getOutputStream()
private fun DataInputStream.bytes(n: Int) = ByteArray(n).also { readFully(it) }
private fun ints(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

class Socks5Tests {
    private lateinit var server: Socks5Server
    private lateinit var echo: ServerSocket

    @Before fun setUp() {
        // Local targets are fine in tests; production refuses them.
        server = Socks5Server(Socks5Server.Config(port = 0, refuseLocalDestinations = false, handshakeTimeoutMs = 3000), { u, p -> u == "mac" && p == "secret" })
        server.start()
        echo = ServerSocket(0, 16, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            while (!echo.isClosed) {
                val s = runCatching { echo.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { s.use { it.getInputStream().copyTo(it.getOutputStream()) } }
            }
        }
    }

    @After fun tearDown() { server.stop(); echo.close() }

    private fun handshake(user: String = "mac", pass: String = "secret"): Triple<Socket, DataInputStream, OutputStream> {
        val s = Socket(InetAddress.getLoopbackAddress(), server.boundPort).apply { soTimeout = 3000 }
        val (i, o) = s.io()
        o.write(ints(5, 1, 2))
        assertArrayEquals(ints(5, 2), i.bytes(2))
        o.write(byteArrayOf(1, user.length.toByte()) + user.toByteArray() + byteArrayOf(pass.length.toByte()) + pass.toByteArray())
        return Triple(s, i, o)
    }

    @Test fun connectsAndRelays() {
        val (s, i, o) = handshake()
        assertArrayEquals(ints(1, 0), i.bytes(2))
        o.write(ints(5, 1, 0) + Socks5.Address.ipv4(ints(127, 0, 0, 1), echo.localPort))
        val reply = i.bytes(10)
        assertEquals(0, reply[1].toInt())
        o.write("hello phone".toByteArray())
        assertEquals("hello phone", String(i.bytes(11)))
        s.close()
    }

    @Test fun connectsByDomainName() {
        val (s, i, o) = handshake()
        i.bytes(2)
        o.write(ints(5, 1, 0) + Socks5.Address.domain("localhost", echo.localPort))
        assertEquals(0, i.bytes(10)[1].toInt())
        s.close()
    }

    @Test fun pipelinedHandshakeIsNotLost() {
        // Greeting, auth, request and payload in one write, the way some clients do it.
        val s = Socket(InetAddress.getLoopbackAddress(), server.boundPort).apply { soTimeout = 3000 }
        val (i, o) = s.io()
        o.write(ints(5, 1, 2) + byteArrayOf(1, 3) + "mac".toByteArray() + byteArrayOf(6) + "secret".toByteArray() +
            ints(5, 1, 0) + Socks5.Address.ipv4(ints(127, 0, 0, 1), echo.localPort) + "early".toByteArray())
        assertArrayEquals(ints(5, 2), i.bytes(2))
        assertArrayEquals(ints(1, 0), i.bytes(2))
        assertEquals(0, i.bytes(10)[1].toInt())
        assertEquals("early", String(i.bytes(5)))
        s.close()
    }

    @Test fun rejectsBadPassword() {
        val (s, i, _) = handshake(pass = "wrong")
        assertArrayEquals(ints(1, 1), i.bytes(2))
        s.close()
    }

    @Test fun rejectsClientsWithoutPasswordMethod() {
        val s = Socket(InetAddress.getLoopbackAddress(), server.boundPort).apply { soTimeout = 3000 }
        val (i, o) = s.io()
        o.write(ints(5, 1, 0))
        assertArrayEquals(ints(5, 0xFF), i.bytes(2))
        s.close()
    }

    @Test fun refusedConnectionGetsRefusedReply() {
        val closed = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).let { val p = it.localPort; it.close(); p }
        val (s, i, o) = handshake()
        i.bytes(2)
        o.write(ints(5, 1, 0) + Socks5.Address.ipv4(ints(127, 0, 0, 1), closed))
        assertEquals(Socks5.Reply.CONNECTION_REFUSED, i.bytes(10)[1].toInt())
        s.close()
    }

    @Test fun forwardsUdpInTcp() {
        val udpEcho = DatagramSocket(0, InetAddress.getLoopbackAddress())
        thread(isDaemon = true) {
            val buf = ByteArray(2048); val p = DatagramPacket(buf, buf.size)
            runCatching { while (true) { udpEcho.receive(p); udpEcho.send(DatagramPacket(p.data, p.length, p.socketAddress)) } }
        }
        val (s, i, o) = handshake()
        i.bytes(2)
        o.write(ints(5, Socks5.Command.FORWARD_UDP, 0, 1, 0, 0, 0, 0, 0, 0))
        assertEquals(0, i.bytes(10)[1].toInt())
        val addr = Socks5.Address.ipv4(ints(127, 0, 0, 1), udpEcho.localPort)
        o.write(Socks5.frameDatagram(addr, "ping".toByteArray()))
        val len = i.readUnsignedShort()
        val hdr = i.readUnsignedByte()
        assertEquals(4, len)
        assertArrayEquals(addr, i.bytes(hdr - 3))
        assertEquals("ping", String(i.bytes(len)))
        s.close(); udpEcho.close()
    }

    @Test fun refusesLocalDestinationsInProduction() {
        val prod = Socks5Server(Socks5Server.Config(port = 0), null)
        prod.start()
        try {
            val s = Socket(InetAddress.getLoopbackAddress(), prod.boundPort).apply { soTimeout = 3000 }
            val (i, o) = s.io()
            o.write(ints(5, 1, 0)); i.bytes(2)
            o.write(ints(5, 1, 0) + Socks5.Address.ipv4(ints(192, 168, 1, 1), 80))
            assertEquals(Socks5.Reply.NETWORK_UNREACHABLE, i.bytes(10)[1].toInt())
            s.close()
        } finally { prod.stop() }
    }

    @Test fun classifiesLocalAddresses() {
        fun v4(vararg b: Int) = Socks5.Address.parse(Socks5.Address.ipv4(ints(*b), 80))!!.isLocalOnly
        assertTrue(v4(10, 0, 0, 1)); assertTrue(v4(192, 168, 0, 1)); assertTrue(v4(100, 64, 0, 1)); assertTrue(v4(224, 0, 0, 251))
        assertFalse(v4(1, 1, 1, 1)); assertFalse(v4(100, 128, 0, 1))
        assertTrue(Socks5.Address.parse(Socks5.Address.domain("printer.local", 631))!!.isLocalOnly)
        assertFalse(Socks5.Address.parse(Socks5.Address.domain("example.com", 443))!!.isLocalOnly)
        val mapped = byteArrayOf(4) + ByteArray(10) + ints(0xff, 0xff, 192, 168, 1, 1) + ints(0, 80)
        assertTrue(Socks5.Address.parse(mapped)!!.isLocalOnly)
    }
}

class PairingTests {
    private var now = 1_000_000L
    private val registry = PairingRegistry(MemoryStore()) { now }

    @Test fun pairsAndVerifies() {
        val code = registry.issueCode()
        assertEquals(6, code.code.length)
        val r = registry.pair(code.code, "m1", "MacBook") as PairingRegistry.PairResult.Success
        assertEquals(43, r.token.length)
        assertTrue(r.token.all { it.isLetterOrDigit() || it == '-' || it == '_' })
        assertTrue(registry.verify("m1", r.token))
        assertFalse(registry.verify("m1", r.token + "x"))
        assertFalse(registry.verify("m2", r.token))
        assertNull(registry.activeCode)
        registry.revoke("m1")
        assertFalse(registry.verify("m1", r.token))
    }

    @Test fun codeExpires() {
        val code = registry.issueCode()
        now += PassthroughProtocol.PAIRING_CODE_LIFETIME_MS + 1
        assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.EXPIRED), registry.pair(code.code, "m1", "Mac"))
    }

    @Test fun codeIsWithdrawnAfterFiveWrongGuesses() {
        val code = registry.issueCode()
        val wrong = if (code.code == "000000") "111111" else "000000"
        repeat(4) { assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair(wrong, "m1", "Mac")) }
        assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.EXPIRED), registry.pair(wrong, "m1", "Mac"))
        assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.EXPIRED), registry.pair(code.code, "m1", "Mac"))
    }

    @Test fun generatesWellFormedTokens() {
        val token = PairingToken.generate()
        assertTrue(PairingToken.isWellFormed(token))
        assertEquals(64, PairingToken.hash(token).length)
    }
}

class ControlTests {
    private val registry = PairingRegistry(MemoryStore())
    private val control = ControlServer(0, 7890, registry, ByteCounter()) { DeviceStatus("Pixel", "5G", "Carrier", 0.8, "background") }

    @Before fun setUp() = control.start()
    @After fun tearDown() = control.stop()

    private fun exchange(s: Socket, m: ControlEnvelope): ControlEnvelope {
        s.getOutputStream().write(m.encodeLine())
        return ControlEnvelope.decode(s.getInputStream().bufferedReader().readLine())
    }

    @Test fun helloPairAndReconnect() {
        val s = Socket(InetAddress.getLoopbackAddress(), control.boundPort).apply { soTimeout = 3000 }
        val reader = s.getInputStream().bufferedReader()
        fun send(m: ControlEnvelope) = s.getOutputStream().write(m.encodeLine())
        send(ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 1, clientID = "mac1", name = "MacBook"))
        val welcome = ControlEnvelope.decode(reader.readLine())
        assertEquals(ControlEnvelope.WELCOME, welcome.t)
        assertEquals(false, welcome.paired)
        assertEquals("Pixel", welcome.deviceName)
        assertEquals(7890, welcome.socksPort)

        val code = registry.issueCode()
        send(ControlEnvelope(ControlEnvelope.PAIR, clientID = "mac1", name = "MacBook", code = code.code))
        val paired = ControlEnvelope.decode(reader.readLine())
        assertEquals(ControlEnvelope.PAIRED, paired.t)
        val token = assertNotNull(paired.token).let { paired.token!! }
        assertEquals(ControlEnvelope.STATUS, ControlEnvelope.decode(reader.readLine()).t)
        assertEquals(1, control.connectedMacs.size)
        s.close()

        val again = Socket(InetAddress.getLoopbackAddress(), control.boundPort).apply { soTimeout = 3000 }
        val w2 = exchange(again, ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 1, clientID = "mac1", name = "MacBook", token = token))
        assertEquals(true, w2.paired)
        again.close()
    }

    @Test fun rejectsOtherProtocolVersions() {
        Socket(InetAddress.getLoopbackAddress(), control.boundPort).use { s ->
            s.soTimeout = 3000
            val r = exchange(s, ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 99, clientID = "x"))
            assertEquals(ControlEnvelope.ERROR, r.t)
            assertEquals("unsupported_version", r.reason)
        }
    }

    @Test fun answersPing() {
        Socket(InetAddress.getLoopbackAddress(), control.boundPort).use { s ->
            s.soTimeout = 3000
            assertEquals(ControlEnvelope.PONG, exchange(s, ControlEnvelope(ControlEnvelope.PING)).t)
        }
    }
}

class WireFormatTests {
    @Test fun omitsNullsLikeSwift() {
        val line = String(ControlEnvelope(ControlEnvelope.PING).encodeLine())
        assertEquals("{\"t\":\"ping\"}\n", line)
    }

    @Test fun decodesSwiftEncodedMessages() {
        // What the Mac's JSONEncoder produces for a hello (key order is not guaranteed).
        val m = ControlEnvelope.decode("{\"name\":\"MacBook Pro\",\"protocolVersion\":1,\"clientID\":\"8F0C\",\"t\":\"hello\",\"token\":\"abc\"}")
        assertEquals(ControlEnvelope.HELLO, m.t)
        assertEquals(1, m.protocolVersion)
        assertEquals("abc", m.token)
        // Unknown future keys are ignored rather than failing the whole message.
        assertEquals(ControlEnvelope.PING, ControlEnvelope.decode("{\"t\":\"ping\",\"future\":true}").t)
    }

    @Test fun statusCarriesNumbersSwiftCanDecode() {
        val s = String(ControlEnvelope(ControlEnvelope.STATUS, battery = 0.82, rxBytes = 5_000_000_000L, timestamp = 1.5).encodeLine())
        assertTrue(s.contains("\"battery\":0.82"))
        assertTrue(s.contains("\"rxBytes\":5000000000"))
        assertTrue(s.contains("\"timestamp\":1.5"))
    }

    @Test fun formatsLikeTheOtherApps() {
        assertEquals("12.4" to "MB/s", ByteFormat.rate(12_400_000.0))
        assertEquals("950" to "B/s", ByteFormat.rate(950.0))
        assertEquals("01:05", ByteFormat.duration(65))
        assertEquals("1:01:05", ByteFormat.duration(3665))
    }

    @Test fun meterComputesRates() {
        var m = TrafficMeter()
        m = m.record(ByteCounter.Snapshot(0, 0, 0, 0), 0)
        m = m.record(ByteCounter.Snapshot(2000, 500, 1, 1), 1000)
        assertEquals(2000.0, m.downRate, 0.01)
        assertEquals(500.0, m.upRate, 0.01)
        assertEquals(60, m.history.size)
    }
}
