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
import java.util.Base64
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

    @Test fun refusesNamesThatResolveToLocalAddresses() {
        // A rebinding DNS answer: an ordinary-looking name that points at loopback.
        val rebinding = object : Egress {
            override fun resolve(host: String): List<java.net.InetAddress> = listOf(InetAddress.getLoopbackAddress())
            override fun bind(socket: Socket) {}
            override fun bind(socket: DatagramSocket) {}
            override val label = "rebinding"
        }
        val prod = Socks5Server(Socks5Server.Config(port = 0), null, EgressProvider { rebinding })
        prod.start()
        try {
            for (name in listOf("rebind.example.com", "127.1", "[::1]")) {
                val s = Socket(InetAddress.getLoopbackAddress(), prod.boundPort).apply { soTimeout = 3000 }
                val (i, o) = s.io()
                o.write(ints(5, 1, 0)); i.bytes(2)
                o.write(ints(5, 1, 0) + Socks5.Address.domain(name, echo.localPort))
                assertEquals(name, Socks5.Reply.NETWORK_UNREACHABLE, i.bytes(10)[1].toInt())
                s.close()
            }
        } finally { prod.stop() }
        // With local destinations allowed (passthrough-devserver), the same answer is used.
        val dev = Socks5Server(Socks5Server.Config(port = 0, refuseLocalDestinations = false), null, EgressProvider { rebinding })
        dev.start()
        try {
            val s = Socket(InetAddress.getLoopbackAddress(), dev.boundPort).apply { soTimeout = 3000 }
            val (i, o) = s.io()
            o.write(ints(5, 1, 0)); i.bytes(2)
            o.write(ints(5, 1, 0) + Socks5.Address.domain("rebind.example.com", echo.localPort))
            assertEquals(Socks5.Reply.SUCCEEDED, i.bytes(10)[1].toInt())
            s.close()
        } finally { dev.stop() }
    }

    @Test fun redactsPrivatePartsOfLogLines() {
        val marked = "connect to ${ptPrivate("example.com:443")} failed: ${ptPrivate(42)}"
        assertEquals("connect to example.com:443 failed: 42", PtLog.render(marked, redacting = false))
        assertEquals("connect to <private> failed: <private>", PtLog.render(marked, redacting = true))
        assertEquals("plain", PtLog.render("plain", redacting = true))
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
    private val registry = PairingRegistry(MemoryStore(), clock = { now })

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

    /** Wrong guesses never lock the right code out; the tenth in all withdraws the code, and says so. Mirrors the Swift test. */
    @Test fun wrongGuessesWithdrawTheCode() {
        var code = registry.issueCode()
        var wrong = if (code.code == "000000") "111111" else "000000"
        // Up to the budget, the right code still works.
        repeat(PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CODE - 1) {
            assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair(wrong, "m1", "Mac"))
        }
        assertTrue("the right code is never locked out", registry.pair(code.code, "m1", "Mac") is PairingRegistry.PairResult.Success)

        // The last wrong guess of the budget withdraws the code.
        code = registry.issueCode()
        wrong = if (code.code == "000000") "111111" else "000000"
        repeat(PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CODE - 1) {
            assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair(wrong, "m2", "Mac"))
        }
        assertFalse(registry.codeWasWithdrawn)
        assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.CODE_WITHDRAWN), registry.pair(wrong, "m2", "Mac"))
        assertNull("withdrawn", registry.activeCode)
        assertTrue("and the app can say why", registry.codeWasWithdrawn)
        assertEquals("not even the right code once withdrawn", PairingRegistry.PairResult.Failure(PairingFailure.EXPIRED), registry.pair(code.code, "m2", "Mac"))
        assertFalse(registry.clients.any { it.id == "m2" })

        // A new code starts over.
        code = registry.issueCode()
        wrong = if (code.code == "000000") "111111" else "000000"
        assertFalse(registry.codeWasWithdrawn)
        assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair(wrong, "m2", "Mac"))
        assertTrue(registry.pair(code.code, "m2", "Mac") is PairingRegistry.PairResult.Success)
    }

    /** A malformed pair costs the code nothing and learns nothing about it. */
    @Test fun malformedPairIsRefusedBeforeTheCode() {
        val code = registry.issueCode()
        repeat(PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CODE) {
            assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair(code.code, "m".repeat(65), "Mac"))
            assertEquals(PairingRegistry.PairResult.Failure(PairingFailure.BAD_CODE), registry.pair("000000", "", "Mac"))
        }
        assertEquals(code, registry.activeCode)
        assertTrue(registry.pair(code.code, "m", "Mac") is PairingRegistry.PairResult.Success)
    }

    /** The SOCKS5 password is derived from the pairing, never the token itself. */
    @Test fun socksPasswordIsDerivedFromThePairing() {
        val r = registry.pair(registry.issueCode().code, "m1", "Mac") as PairingRegistry.PairResult.Success
        assertTrue(registry.verifySocks("m1", ControlAuth.socksPassword(ControlAuth.key(r.token))))
        assertFalse("the token is not the password", registry.verifySocks("m1", r.token))
        assertFalse(registry.verifySocks("m2", ControlAuth.socksPassword(ControlAuth.key(r.token))))
    }

    @Test fun generatesWellFormedTokens() {
        val token = PairingToken.generate()
        assertTrue(PairingToken.isWellFormed(token))
        assertEquals(64, PairingToken.hash(token).length)
    }
}

class ControlTests {
    private var now = System.currentTimeMillis()
    private val registry = PairingRegistry(MemoryStore(), clock = { now }).apply { withSealing() }
    private var control = ControlServer(0, 7890, registry, ByteCounter()) { DeviceStatus("Pixel", "5G", "Carrier", 0.8, "background") }

    @Before fun setUp() = control.start()
    @After fun tearDown() = control.stop()

    /** A Mac's end of one control connection. */
    private inner class Mac(val clientID: String = "mac1") {
        val socket = Socket(InetAddress.getLoopbackAddress(), control.boundPort).apply { soTimeout = 5000 }
        private val reader = socket.getInputStream().bufferedReader()
        val nonce = ControlAuth.nonce()
        fun send(m: ControlEnvelope) = socket.getOutputStream().write(m.encodeLine())
        fun receive(): ControlEnvelope = ControlEnvelope.decode(reader.readLine())
        /** Null once the phone has closed the connection. */
        fun receiveOrNull(): String? = runCatching { reader.readLine() }.getOrNull()
        fun hello(): ControlEnvelope {
            send(ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 2, clientID = clientID, name = "MacBook", nonce = Base64.getEncoder().encodeToString(nonce)))
            return receive()
        }
        fun auth(token: String, welcome: ControlEnvelope) {
            val proof = ControlAuth.macProof(ControlAuth.key(token), clientID, nonce, ControlAuth.decodeNonce(welcome.nonce)!!)
            send(ControlEnvelope(ControlEnvelope.AUTH, proof = Base64.getEncoder().encodeToString(proof)))
        }
        /** Everything sent before it has been handled; returns what came first. */
        fun sync(): List<ControlEnvelope> {
            send(ControlEnvelope(ControlEnvelope.PING))
            val seen = mutableListOf<ControlEnvelope>()
            while (true) { val m = receive(); if (m.t == ControlEnvelope.PONG) return seen; seen += m }
        }
    }

    private fun paired(clientID: String = "mac1") = (registry.pair(registry.issueCode().code, clientID, "MacBook") as PairingRegistry.PairResult.Success).token

    @Test fun helloPairAndReconnect() {
        val mac = Mac()
        val welcome = mac.hello()
        assertEquals(ControlEnvelope.WELCOME, welcome.t)
        assertEquals(false, welcome.paired)
        assertNull(welcome.proof)
        assertNotNull("a nonce even when unpaired", ControlAuth.decodeNonce(welcome.nonce))
        assertNull("nothing about the phone before the Mac is proven", welcome.deviceName)

        val code = registry.issueCode()
        mac.send(ControlEnvelope(ControlEnvelope.PAIR, clientID = "mac1", name = "MacBook", code = code.code))
        val paired = mac.receive()
        assertEquals(ControlEnvelope.PAIRED, paired.t)
        val token = paired.token!!
        assertEquals(ControlEnvelope.STATUS, mac.receive().t)
        assertEquals(1, control.connectedMacs.size)
        mac.socket.close()

        // Reconnect: the phone proves the pairing first (the same proof the Swift side checks), then the Mac does.
        val again = Mac()
        val w2 = again.hello()
        assertEquals(true, w2.paired)
        assertNull(w2.token)
        val expected = ControlAuth.phoneProof(ControlAuth.key(token), "mac1", again.nonce, ControlAuth.decodeNonce(w2.nonce)!!)
        assertEquals(Base64.getEncoder().encodeToString(expected), w2.proof)
        again.auth(token, w2)
        val first = again.receive()
        assertEquals("authenticated: status flows, the first at once", ControlEnvelope.STATUS, first.t)
        assertEquals("Pixel", first.deviceName)
        again.socket.close()
    }

    /** A welcome holds what the handshake needs and nothing else: no name, radio, carrier, battery, hosting, IPv6 or port, paired or not. */
    @Test fun welcomeTellsAStrangerNothingAboutThePhone() {
        fun welcomeKeys(clientID: String): Set<String> {
            val mac = Mac(clientID)
            mac.send(ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = 2, clientID = clientID, name = "MacBook", nonce = Base64.getEncoder().encodeToString(mac.nonce)))
            val line = mac.receiveOrNull()!!
            mac.socket.close()
            return kotlinx.serialization.json.Json.parseToJsonElement(line).let { (it as kotlinx.serialization.json.JsonObject).keys }
        }
        assertEquals(setOf("t", "protocolVersion", "paired", "nonce"), welcomeKeys("stranger"))
        paired("mac1")
        assertEquals(setOf("t", "protocolVersion", "paired", "nonce", "proof"), welcomeKeys("mac1"))
    }

    private fun Mac.pair(code: String): String? {
        send(ControlEnvelope(ControlEnvelope.PAIR, clientID = clientID, name = "MacBook", code = code))
        val reply = receive()
        return if (reply.t == ControlEnvelope.PAIRED) reply.t else reply.reason
    }

    /** A few wrong codes close the connection that sent them; the code still works on a new one. */
    @Test fun wrongCodesCloseTheirConnectionOnly() {
        val code = registry.issueCode().code
        val wrong = if (code == "000000") "111111" else "000000"
        val guesser = Mac()
        guesser.hello()
        repeat(PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CONNECTION - 1) { assertEquals("bad_code", guesser.pair(wrong)) }
        assertEquals("locked", guesser.pair(wrong))
        assertNull("and the connection is closed", guesser.receiveOrNull())

        val mac = Mac()
        mac.hello()
        assertEquals("the right code works on a new connection", ControlEnvelope.PAIRED, mac.pair(code))
        mac.socket.close()
    }

    /** Opening connection after connection buys no more guesses: the code takes so many wrong ones in all, then is withdrawn. */
    @Test fun wrongCodesOverManyConnectionsWithdrawTheCode() {
        val code = registry.issueCode().code
        val wrong = if (code == "000000") "111111" else "000000"
        var guesses = 0
        var last: String? = null
        while (guesses < PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CODE) {
            val guesser = Mac()
            guesser.hello()
            for (i in 0 until PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CONNECTION) {
                if (guesses == PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CODE) break
                last = guesser.pair(wrong)
                guesses++
            }
            guesser.socket.close()
        }
        assertEquals("code_withdrawn", last)
        assertNull(registry.activeCode)
        assertTrue(registry.codeWasWithdrawn)
        val mac = Mac()
        mac.hello()
        assertEquals("a new code must be shown", "expired", mac.pair(code))
        mac.socket.close()
    }

    /** A Mac from before version 2 (token in hello) is refused, with our version so it knows who to update. */
    @Test fun rejectsOtherProtocolVersions() {
        val token = paired()
        for (version in listOf(1, 99)) {
            val mac = Mac()
            mac.send(ControlEnvelope(ControlEnvelope.HELLO, protocolVersion = version, clientID = "mac1", token = token))
            val r = mac.receive()
            assertEquals(ControlEnvelope.ERROR, r.t)
            assertEquals("unsupported_version", r.reason)
            assertEquals(PassthroughProtocol.VERSION, r.protocolVersion)
            assertNull("and the connection is closed", mac.receiveOrNull())
        }
        assertTrue(control.connectedMacs.isEmpty())
    }

    /** Before the Mac proves the pairing nothing privileged is acted on; a wrong proof ends the connection. */
    @Test fun privilegedMessagesNeedTheMacsProof() {
        val token = paired()
        val mac = Mac()
        val welcome = mac.hello()
        assertEquals(true, welcome.paired)
        val grant = ControlEnvelope(ControlEnvelope.SHELL_GRANT, shellKey = Base64.getEncoder().encodeToString(ByteArray(32) { 1 }),
            certSHA256 = "b".repeat(64), shellPort = 7893, addresses = emptyList(), macName = "M")
        mac.send(grant)
        assertEquals("no shellGranted or status before auth", emptyList<String>(), mac.sync().map { it.t })
        assertNull(registry.sealedPendingShellKey("mac1"))
        assertTrue(control.connectedMacs.isEmpty())

        mac.auth(PairingToken.generate(), welcome)
        val refused = mac.receive()
        assertEquals(ControlEnvelope.ERROR, refused.t)
        assertEquals("not_authenticated", refused.reason)
        assertNull("and the connection is closed", mac.receiveOrNull())

        val good = Mac()
        good.auth(token, good.hello())
        good.send(grant)
        assertTrue(good.sync().any { it.t == ControlEnvelope.SHELL_GRANTED })
        assertNotNull(registry.sealedPendingShellKey("mac1"))
        good.socket.close()
    }

    /** A pair before hello (which checks the version) is not taken. */
    @Test fun pairNeedsHello() {
        val code = registry.issueCode()
        val mac = Mac()
        mac.send(ControlEnvelope(ControlEnvelope.PAIR, clientID = "mac1", name = "MacBook", code = code.code))
        assertEquals("not_authenticated", mac.receive().reason)
        assertTrue(registry.clients.isEmpty())
        mac.socket.close()
    }

    /** A connection that proves nothing is closed after the timeout, unless a code is showing; once it goes, so does the extra time. */
    @Test fun unauthenticatedConnectionsAreClosed() {
        control.stop()
        now = System.currentTimeMillis()
        control = ControlServer(0, 7890, registry, ByteCounter(), unauthenticatedTimeoutMs = 1000) { DeviceStatus("Pixel", hosting = "background") }
        control.start()
        val silent = Mac()
        val started = System.currentTimeMillis()
        assertNull(silent.receiveOrNull())
        assertTrue(System.currentTimeMillis() - started < 4000)

        registry.issueCode()
        val pairing = Mac("mac2")
        pairing.hello()
        Thread.sleep(2500)
        assertEquals("still open while the code shows", 0, pairing.sync().size)
        registry.clearCode()
        assertNull(pairing.receiveOrNull())
    }

    /** An authenticated Mac that stops talking is dropped. */
    @Test fun silentMacIsDropped() {
        control.stop()
        control = ControlServer(0, 7890, registry, ByteCounter(), silenceLimitMs = 1000) { DeviceStatus("Pixel", hosting = "background") }
        control.start()
        val token = paired()
        val mac = Mac()
        mac.auth(token, mac.hello())
        mac.sync()
        assertEquals(1, control.connectedMacs.size)
        var lines = 0
        while (mac.receiveOrNull() != null) lines++
        assertTrue("closed after a second or two of silence", lines < 5)
        // The socket closes before the peer leaves the list; give a slow runner a moment.
        val deadline = System.currentTimeMillis() + 2000
        while (control.connectedMacs.isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertTrue(control.connectedMacs.isEmpty())
    }

    @Test fun answersPing() {
        Socket(InetAddress.getLoopbackAddress(), control.boundPort).use { s ->
            s.soTimeout = 3000
            s.getOutputStream().write(ControlEnvelope(ControlEnvelope.PING).encodeLine())
            assertEquals(ControlEnvelope.PONG, ControlEnvelope.decode(s.getInputStream().bufferedReader().readLine()).t)
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
        val m = ControlEnvelope.decode("{\"name\":\"MacBook Pro\",\"protocolVersion\":2,\"clientID\":\"8F0C\",\"t\":\"hello\",\"nonce\":\"abc\"}")
        assertEquals(ControlEnvelope.HELLO, m.t)
        assertEquals(2, m.protocolVersion)
        assertEquals("abc", m.nonce)
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
