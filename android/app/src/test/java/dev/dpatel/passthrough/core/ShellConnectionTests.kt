package dev.dpatel.passthrough.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.channels.Channels
import java.nio.channels.Pipe
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread

class ShellConnectionTests {
    private val shellKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
    private val credential = ShellCredential(
        macID = "mac1", macName = "Studio", certSHA256 = "00".repeat(32), shellKey = shellKey,
        phoneID = "phone-1", port = RemoteShell.DEFAULT_PORT, addresses = listOf("192.168.1.2"),
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val cleanups = mutableListOf<() -> Unit>()

    @After fun tearDown() {
        cleanups.forEach { runCatching(it) }
        scope.cancel()
    }

    private fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)
    private fun unb64(s: String?) = Base64.getDecoder().decode(requireNotNull(s))

    /** The Mac's side of a connection, blocking, on the test thread or its own. */
    private inner class FakeMac(input: InputStream, private val output: OutputStream) {
        private val lines = LineReader(input, RemoteShell.LINE_LIMIT)
        val nonce = ByteArray(32).also { SecureRandom().nextBytes(it) }

        fun send(m: ShellEnvelope) { output.write(m.encodeLine()); output.flush() }
        fun receive(): ShellEnvelope = ShellEnvelope.decode(requireNotNull(lines.next()) { "client closed" })

        /** Challenge, check the proof, then `ready` (only if it is valid). */
        fun handshake(): Boolean {
            send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(nonce)))
            val proof = receive()
            val valid = proof.t == ShellEnvelope.PROOF && proof.phoneID == credential.phoneID &&
                RemoteShell.proofIsValid(unb64(proof.mac), shellKey, nonce)
            if (valid) send(ShellEnvelope(ShellEnvelope.READY))
            return valid
        }
    }

    /** A connection to a fake Mac over two in-memory pipes (no sockets, no TLS). */
    private fun piped(liveness: ShellLiveness = ShellLiveness()): Pair<ShellConnection, FakeMac> {
        val toMac = Pipe.open()
        val toPhone = Pipe.open()
        val connection = ShellConnection(
            Channels.newInputStream(toPhone.source()), Channels.newOutputStream(toMac.sink()), credential, scope,
            liveness = liveness,
        )
        val mac = FakeMac(Channels.newInputStream(toMac.source()), Channels.newOutputStream(toPhone.sink()))
        cleanups += { connection.close() }
        cleanups += { toMac.source().close(); toPhone.sink().close() }
        return connection to mac
    }

    private fun events(connection: ShellConnection): Channel<ShellEvent> {
        val channel = Channel<ShellEvent>(Channel.UNLIMITED)
        scope.launch { connection.events.collect { channel.send(it) } }
        return channel
    }

    private suspend inline fun <reified T : ShellEvent> Channel<ShellEvent>.next(): T = withTimeout(5000) {
        while (true) {
            val e = receive()
            if (e is T) return@withTimeout e
        }
        @Suppress("UNREACHABLE_CODE") error("unreachable")
    }

    private fun macThread(block: () -> Unit): Thread {
        val failure = arrayOfNulls<Throwable>(1)
        val t = thread(name = "fake-mac") { try { block() } catch (e: Throwable) { failure[0] = e } }
        cleanups += { t.join(5000) }
        return t
    }

    // MARK: Brief

    @Test fun handshakeSendsValidProof() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val valid = AtomicBoolean(false)
        val t = macThread { valid.set(mac.handshake()) }
        withTimeout(5000) { connection.awaitReady() }
        events.next<ShellEvent.Ready>()
        t.join(5000)
        assertTrue("fake Mac accepted the proof", valid.get())
    }

    /** A ready connection the Mac stops answering on (its path died without closing) is given up. */
    @Test fun aSilentConnectionIsGivenUp() = runBlocking {
        val liveness = ShellLiveness(intervalMs = 200, silenceMs = 600)
        val (connection, mac) = piped(liveness)
        val events = events(connection)
        macThread { mac.handshake() }   // then reads nothing and says nothing
        events.next<ShellEvent.Ready>()
        val readyAt = System.nanoTime()
        val gone = events.next<ShellEvent.Disconnected>()
        assertTrue(gone.error is ShellConnectError.StoppedAnswering)
        assertTrue("within the silence limit", (System.nanoTime() - readyAt) / 1_000_000 < liveness.silenceMs + 600)
    }

    /** A quiet connection whose pings the Mac answers stays, well past the silence limit. */
    @Test fun aQuietConnectionThatAnswersPingsStays() = runBlocking {
        val (connection, mac) = piped(ShellLiveness(intervalMs = 200, silenceMs = 600))
        val events = events(connection)
        val pings = AtomicInteger(0)
        macThread {
            mac.handshake()
            while (true) {
                val m = runCatching { mac.receive() }.getOrNull() ?: break
                if (m.t == ShellEnvelope.PING) { pings.incrementAndGet(); mac.send(ShellEnvelope(ShellEnvelope.PONG)) }
            }
        }
        events.next<ShellEvent.Ready>()
        val gone = withTimeoutOrNull(2000) { events.next<ShellEvent.Disconnected>() }
        assertNull("still connected", gone)
        assertTrue("it pinged", pings.get() > 0)
    }

    @Test fun outputEventsDecodeBase64() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val bytes = ByteArray(5000) { (it * 7).toByte() }
        macThread {
            mac.handshake()
            mac.send(ShellEnvelope(ShellEnvelope.OUTPUT, session = "s1", data = b64(bytes)))
        }
        val output = events.next<ShellEvent.Output>()
        assertEquals("s1", output.session)
        assertArrayEquals(bytes, output.data)
    }

    @Test fun inputIsChunked() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val bytes = ByteArray(40_000) { it.toByte() }
        val received = mutableListOf<ShellEnvelope>()
        val t = macThread {
            mac.handshake()
            received += mac.receive() // attach
            repeat(3) { received += mac.receive() }
        }
        connection.attach("s1", 80, 24)
        connection.input(bytes)
        events.next<ShellEvent.Ready>()
        t.join(5000)
        assertEquals(ShellEnvelope.ATTACH, received[0].t)
        assertEquals(80, received[0].cols)
        val inputs = received.drop(1)
        assertEquals(listOf(ShellEnvelope.INPUT, ShellEnvelope.INPUT, ShellEnvelope.INPUT), inputs.map { it.t })
        assertTrue(inputs.all { it.session == "s1" })
        val pieces = inputs.map { unb64(it.data) }
        assertEquals(listOf(RemoteShell.OUTPUT_CHUNK, RemoteShell.OUTPUT_CHUNK, 40_000 - 2 * RemoteShell.OUTPUT_CHUNK), pieces.map { it.size })
        assertArrayEquals(bytes, pieces.reduce { a, b -> a + b })
    }

    @Test fun detachedEventSurfaces() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val after = mutableListOf<ShellEnvelope>()
        val detachedSent = java.util.concurrent.CountDownLatch(1)
        val t = macThread {
            mac.handshake()
            mac.receive() // attach
            mac.send(ShellEnvelope(ShellEnvelope.DETACHED, session = "s1"))
            detachedSent.countDown()
            after += mac.receive()
        }
        connection.attach("s1", 80, 24)
        assertEquals("s1", events.next<ShellEvent.Detached>().session)
        // The session is no longer this connection's: keystrokes go nowhere.
        connection.input("ls\n".toByteArray())
        connection.list()
        t.join(5000)
        assertEquals(listOf(ShellEnvelope.LIST), after.map { it.t })
    }

    @Test fun fingerprintMatchesSha256Hex() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", PinnedTls.fingerprint("abc".toByteArray()))
        val cert = testCertificate()
        assertEquals(64, PinnedTls.fingerprint(cert.encoded).length)
        assertTrue(PinnedTls.fingerprint(cert.encoded).all { it in '0'..'9' || it in 'a'..'f' })
    }

    // MARK: Protocol parity with ShellClient.swift

    @Test fun commandsBeforeReadyAreQueued() = runBlocking {
        val (connection, mac) = piped()
        connection.list()
        connection.open(100, 30)
        val received = mutableListOf<ShellEnvelope>()
        val t = macThread {
            mac.handshake()
            repeat(2) { received += mac.receive() }
        }
        withTimeout(5000) { connection.awaitReady() }
        t.join(5000)
        assertEquals(listOf(ShellEnvelope.LIST, ShellEnvelope.OPEN), received.map { it.t })
        assertEquals(100, received[1].cols)
        assertEquals(30, received[1].rows)
    }

    @Test fun refusalFailsAndDisconnects() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread {
            mac.send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(mac.nonce)))
            mac.receive()
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.NOT_AUTHORIZED.wire))
        }
        try {
            withTimeout(5000) { connection.awaitReady() }
            fail("expected a refusal")
        } catch (e: ShellConnectError.Refused) {
            assertEquals(ShellError.NOT_AUTHORIZED, e.reason)
        }
        assertEquals(ShellError.NOT_AUTHORIZED, events.next<ShellEvent.Failed>().error)
        assertTrue(events.next<ShellEvent.Disconnected>().error is ShellConnectError.Refused)
    }

    @Test fun shortNonceIsAProtocolViolation() = runBlocking {
        val (connection, mac) = piped()
        macThread { mac.send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(ByteArray(16)))) }
        try {
            withTimeout(5000) { connection.awaitReady() }
            fail("expected a protocol violation")
        } catch (_: ShellConnectError.ProtocolViolation) {
        }
    }

    @Test fun readyBeforeChallengeIsAProtocolViolation() = runBlocking {
        val (connection, mac) = piped()
        macThread { mac.send(ShellEnvelope(ShellEnvelope.READY)) }
        try {
            withTimeout(5000) { connection.awaitReady() }
            fail("expected a protocol violation")
        } catch (_: ShellConnectError.ProtocolViolation) {
        }
    }

    @Test fun eventsDecode() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val info = ShellSessionInfo("s1", "zsh", 1.0, 2.0, true)
        val entry = ShellHistoryEntry("h1", "zsh", "Pixel", 1.0, 2.0, 0, 42)
        val pong = mutableListOf<ShellEnvelope>()
        macThread {
            mac.handshake()
            mac.send(ShellEnvelope(ShellEnvelope.SESSIONS, sessions = listOf(info)))
            mac.send(ShellEnvelope(ShellEnvelope.OPENED, session = "s2", cols = 80, rows = 24))
            mac.send(ShellEnvelope(ShellEnvelope.ATTACHED, session = "s2"))
            mac.send(ShellEnvelope(ShellEnvelope.HISTORY_LIST, history = listOf(entry)))
            mac.send(ShellEnvelope(ShellEnvelope.TRANSCRIPT_DATA, session = "h1", data = b64("hi".toByteArray()), cols = 48, rows = 20, done = true))
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.TOO_MANY_SESSIONS.wire))
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.NO_SUCH_SESSION.wire, session = "h9"))
            mac.send(ShellEnvelope(ShellEnvelope.PING))
            pong += mac.receive()
            mac.send(ShellEnvelope(ShellEnvelope.ENDED, session = "s2", exitStatus = 2))
        }
        assertEquals(listOf(info), events.next<ShellEvent.Sessions>().sessions)
        assertEquals("s2", events.next<ShellEvent.Opened>().session)
        assertEquals("s2", events.next<ShellEvent.Attached>().session)
        assertEquals(listOf(entry), events.next<ShellEvent.History>().entries)
        val transcript = events.next<ShellEvent.Transcript>()
        assertEquals("h1", transcript.session)
        assertArrayEquals("hi".toByteArray(), transcript.data)
        assertTrue(transcript.done)
        assertEquals(48, transcript.cols)
        assertEquals(20, transcript.rows)
        val unnamed = events.next<ShellEvent.Failed>()
        assertEquals(ShellError.TOO_MANY_SESSIONS, unnamed.error)
        assertNull(unnamed.session)
        val named = events.next<ShellEvent.Failed>()
        assertEquals(ShellError.NO_SUCH_SESSION, named.error)
        assertEquals("h9", named.session)
        val ended = events.next<ShellEvent.Ended>()
        assertEquals("s2", ended.session)
        assertEquals(2, ended.exitStatus)
        assertEquals(listOf(ShellEnvelope.PONG), pong.map { it.t })
    }

    @Test fun macClosingDisconnectsOnce() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        val closed = java.util.concurrent.CountDownLatch(1)
        macThread { mac.handshake(); closed.await() }
        events.next<ShellEvent.Ready>()
        cleanups.removeAt(1).invoke() // close the pipes the Mac writes to
        closed.countDown()
        assertTrue(events.next<ShellEvent.Disconnected>().error != null)
        connection.close()
        assertNull(withTimeoutOrNullMs(300) { events.next<ShellEvent.Disconnected>() })
    }

    @Test fun closeDisconnectsWithoutError() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread { mac.handshake() }
        events.next<ShellEvent.Ready>()
        connection.close()
        assertNull(events.next<ShellEvent.Disconnected>().error)
    }

    /** Polls until [owner] has no live children; false if some remain after 5 s. */
    private fun settles(owner: CoroutineScope): Boolean {
        val job = requireNotNull(owner.coroutineContext[kotlinx.coroutines.Job])
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            if (job.children.none { it.isActive }) return true
            Thread.sleep(20)
        }
        return false
    }

    /** A race's loser is closed and never collected: nothing it started may stay suspended in the owner's scope. */
    @Test fun closingAnUncollectedConnectionLeavesNoWork() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        cleanups += { owner.cancel() }
        val toMac = Pipe.open()
        val toPhone = Pipe.open()
        val connection = ShellConnection(Channels.newInputStream(toPhone.source()), Channels.newOutputStream(toMac.sink()), credential, owner)
        val mac = FakeMac(Channels.newInputStream(toMac.source()), Channels.newOutputStream(toPhone.sink()))
        cleanups += { toMac.source().close(); toPhone.sink().close() }
        macThread {
            mac.handshake()
            mac.send(ShellEnvelope(ShellEnvelope.SESSIONS, sessions = emptyList()))
        }
        withTimeout(5000) { connection.awaitReady() }
        connection.close()
        assertTrue("no coroutine left in the owner's scope", settles(owner))
    }

    /** The same when the Mac ended it first (its Disconnected waits for a subscriber until close). */
    @Test fun closingAnUncollectedConnectionTheMacEndedLeavesNoWork() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        cleanups += { owner.cancel() }
        val toMac = Pipe.open()
        val toPhone = Pipe.open()
        val connection = ShellConnection(Channels.newInputStream(toPhone.source()), Channels.newOutputStream(toMac.sink()), credential, owner)
        val mac = FakeMac(Channels.newInputStream(toMac.source()), Channels.newOutputStream(toPhone.sink()))
        cleanups += { toMac.source().close() }
        macThread {
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.NOT_AUTHORIZED.wire))
            toPhone.sink().close()
        }
        val refused = runCatching { withTimeout(5000) { connection.awaitReady() } }.exceptionOrNull()
        assertTrue(refused is ShellConnectError.Refused)
        connection.close()
        assertTrue("no coroutine left in the owner's scope", settles(owner))
    }

    @Test fun cancellingTheScopeHangsUp() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val toMac = Pipe.open()
        val toPhone = Pipe.open()
        ShellConnection(Channels.newInputStream(toPhone.source()), Channels.newOutputStream(toMac.sink()), credential, owner)
        val mac = FakeMac(Channels.newInputStream(toMac.source()), Channels.newOutputStream(toPhone.sink()))
        cleanups += { toMac.source().close(); toPhone.sink().close() }
        val hungUp = java.util.concurrent.CountDownLatch(1)
        macThread {
            mac.send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(mac.nonce)))
            mac.receive() // proof
            if (runCatching { mac.receive() }.isFailure) hungUp.countDown()
        }
        Thread.sleep(200)
        owner.cancel()
        assertTrue("the Mac sees the phone hang up", hungUp.await(5, java.util.concurrent.TimeUnit.SECONDS))
    }

    @Test fun overlongLineEndsTheConnection() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread {
            mac.handshake()
            runCatching { mac.send(ShellEnvelope(ShellEnvelope.OUTPUT, session = "s1", data = "A".repeat(RemoteShell.LINE_LIMIT + 10))) }
        }
        events.next<ShellEvent.Ready>()
        assertTrue(events.next<ShellEvent.Disconnected>().error is ShellConnectError.ProtocolViolation)
    }

    private suspend fun <T> withTimeoutOrNullMs(ms: Long, block: suspend () -> T): T? =
        kotlinx.coroutines.withTimeoutOrNull(ms) { block() }

    // MARK: Pinned TLS and ShellClient

    private fun testKeyStore(): KeyStore =
        KeyStore.getInstance("PKCS12").apply { load(ByteArrayInputStream(Base64.getDecoder().decode(TEST_P12)), TEST_PASSWORD) }

    private fun testCertificate() = testKeyStore().getCertificate("mac") as X509Certificate

    /** A TLS 1.3 listener on loopback presenting the test certificate, running [serve] per connection. */
    private fun tlsServer(serve: (SSLSocket) -> Unit): Int {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(testKeyStore(), TEST_PASSWORD) }
        val context = SSLContext.getInstance("TLSv1.3").apply { init(kmf.keyManagers, null, null) }
        val server = context.serverSocketFactory.createServerSocket(0, 8, InetAddress.getLoopbackAddress()) as SSLServerSocket
        server.enabledProtocols = arrayOf("TLSv1.3")
        cleanups += { server.close() }
        thread(name = "tls-server", isDaemon = true) {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() as SSLSocket }.getOrNull() ?: break
                thread(isDaemon = true) { runCatching { socket.use(serve) } }
            }
        }
        return server.localPort
    }

    private fun serveMac(socket: SSLSocket) {
        val mac = FakeMac(socket.inputStream, socket.outputStream)
        if (mac.handshake()) while (true) {
            val m = mac.receive()
            if (m.t == ShellEnvelope.LIST) mac.send(ShellEnvelope(ShellEnvelope.SESSIONS, sessions = emptyList()))
        }
    }

    @Test fun pinnedSocketAcceptsOnlyThePinnedCertificate() {
        val port = tlsServer { it.startHandshake() }
        val pin = PinnedTls.fingerprint(testCertificate().encoded)
        PinnedTls.socket("127.0.0.1", port, pin).use { assertEquals("TLSv1.3", it.session.protocol) }
        try {
            PinnedTls.socket("127.0.0.1", port, "00".repeat(32)).close()
            fail("a certificate that isn't pinned must be refused")
        } catch (_: SSLHandshakeException) {
        }
        // The pin is compared exactly: uppercase hex is not the stored form.
        try {
            PinnedTls.socket("127.0.0.1", port, pin.uppercase()).close()
            fail("pin comparison must be exact")
        } catch (_: SSLHandshakeException) {
        }
    }

    @Test fun clientTriesCandidatesInOrderAndAuthorizes() = runBlocking {
        val port = tlsServer(::serveMac)
        // Nothing listens on the first address's port; a closed port fails fast.
        val dead = ServerSocket(0).use { it.localPort }
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port, addresses = listOf("127.0.0.1"))
        val connection = withTimeout(10_000) { ShellClient.connect(cred, "127.0.0.1" to dead, scope) }
        cleanups += { connection.close() }
        val events = events(connection)
        connection.list()
        assertEquals(emptyList<ShellSessionInfo>(), events.next<ShellEvent.Sessions>().sessions)
    }

    /** A plain TCP listener that accepts and never answers (a blackholed route, say). */
    private fun silentServer(): Pair<Int, LinkedBlockingQueue<Socket>> {
        val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        val held = LinkedBlockingQueue<Socket>()
        cleanups += { server.close(); held.forEach { it.close() } }
        thread(isDaemon = true) {
            while (true) held.put(runCatching { server.accept() }.getOrNull() ?: break)
        }
        return server.localPort to held
    }

    /** True once the phone side has hung up [socket]: everything it sent is read, then end of stream. */
    private fun hungUp(socket: Socket): Boolean {
        socket.soTimeout = 3000
        val buffer = ByteArray(4096)
        return try {
            while (socket.getInputStream().read(buffer) >= 0) Unit
            true
        } catch (_: SocketTimeoutException) {
            false
        } catch (_: IOException) {
            true
        }
    }

    @Test fun clientStopsAtAMacRefusal() = runBlocking<Unit> {
        val refusing = tlsServer { socket ->
            val mac = FakeMac(socket.inputStream, socket.outputStream)
            mac.send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(mac.nonce)))
            mac.receive()
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.NOT_AUTHORIZED.wire))
        }
        // The next address never answers: the refusal must not wait for it.
        val (silent, held) = silentServer()
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = silent, addresses = listOf("127.0.0.1"))
        val started = System.nanoTime()
        try {
            withTimeout(10_000) { ShellClient.connect(cred, "127.0.0.1" to refusing, scope) }
            fail("expected a refusal")
        } catch (e: ShellConnectError.Refused) {
            assertEquals(ShellError.NOT_AUTHORIZED, e.reason)
        }
        assertTrue("a refusal ends every attempt at once", (System.nanoTime() - started) / 1_000_000 < ShellClient.ATTEMPT_TIMEOUT_MS / 2)
        held.poll(200, TimeUnit.MILLISECONDS)?.let { assertTrue("an attempt still dialling is dropped", hungUp(it)) }
    }

    @Test fun clientDoesNotWaitForASilentFirstAddress() = runBlocking {
        val port = tlsServer(::serveMac)
        val (silent, held) = silentServer()
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port, addresses = listOf("127.0.0.1"))
        val started = System.nanoTime()
        val connection = withTimeout(10_000) { ShellClient.connect(cred, "127.0.0.1" to silent, scope) }
        cleanups += { connection.close() }
        val elapsed = (System.nanoTime() - started) / 1_000_000
        assertTrue("took $elapsed ms: the good address waited for the silent one", elapsed < ShellClient.STAGGER_MS + 1500)
        val dialled = held.poll(1, TimeUnit.SECONDS)
        assertTrue("the silent address was dialled first", dialled != null)
        assertTrue("the losing attempt is dropped", hungUp(dialled!!))
        val events = events(connection)
        connection.list()
        assertEquals(emptyList<ShellSessionInfo>(), events.next<ShellEvent.Sessions>().sessions)
    }

    @Test fun clientWithNoAddressFails() = runBlocking {
        try {
            ShellClient.connect(credential.copy(addresses = emptyList()), null, scope)
            fail("expected noAddress")
        } catch (_: ShellConnectError.NoAddress) {
        }
    }

    @Test fun candidatesPutDiscoveredFirst() {
        val cred = credential.copy(port = 7022, addresses = listOf("10.0.0.2", "100.64.0.1"))
        assertEquals(listOf("studio.local" to 7893, "10.0.0.2" to 7022, "100.64.0.1" to 7022), ShellClient.candidates(cred, "studio.local" to 7893))
        assertEquals(listOf("10.0.0.2" to 7022, "100.64.0.1" to 7022), ShellClient.candidates(cred, null))
        assertEquals(emptyList<Pair<String, Int>>(), ShellClient.candidates(cred.copy(port = 70_000), null))
    }

    @Test fun credentialNeverPrintsItsKey() {
        assertFalse(credential.toString().contains(b64(shellKey)))
        assertFalse(credential.toString().contains(shellKey.contentToString()))
    }

    // MARK: iroh candidate (mirrors ShellClientIrohTests.swift; the iroh dial is a fake: no native library on the JVM)

    private val irohID = "ab".repeat(32)

    private fun tcp(host: String, port: Int = RemoteShell.DEFAULT_PORT) = ShellCandidate.Tcp(host, port)

    @Test fun scheduleIrohAfterTcp() {
        val cred = credential.copy(addresses = listOf("192.168.1.2", "100.100.1.1"), irohID = irohID)
        val plan = ShellClient.schedule(cred, null, ShellConnectMode.AUTOMATIC)
        assertEquals(listOf(tcp("192.168.1.2"), tcp("100.100.1.1"), ShellCandidate.Iroh), plan.map { it.candidate })
        assertEquals(listOf(0L, 250L, 750L), plan.map { it.delayMs })

        // With more addresses iroh still starts 750 ms after the first, ahead of later ones.
        val many = ShellClient.schedule(cred.copy(addresses = (1..5).map { "10.0.0.$it" }), null, ShellConnectMode.AUTOMATIC)
        assertEquals(listOf(0L, 250L, 500L, 750L, 750L, 1000L), many.map { it.delayMs })
        assertEquals("a TLS candidate due at the same time goes first", ShellCandidate.Iroh, many[4].candidate)
    }

    @Test fun scheduleIrohImmediateWhenNoTcp() {
        val plan = ShellClient.schedule(credential.copy(addresses = emptyList(), irohID = irohID), null, ShellConnectMode.AUTOMATIC)
        assertEquals(listOf(ShellDial(ShellCandidate.Iroh, 0L)), plan)
    }

    @Test fun localOnlyHasNoIroh() {
        val cred = credential.copy(irohID = irohID)
        assertEquals(listOf(ShellDial(tcp("192.168.1.2"), 0L)), ShellClient.schedule(cred, null, ShellConnectMode.LOCAL_ONLY))
        assertTrue(ShellClient.schedule(cred.copy(addresses = emptyList()), null, ShellConnectMode.LOCAL_ONLY).isEmpty())
        assertFalse("no iroh without the Mac's endpoint id",
            ShellClient.schedule(credential.copy(addresses = emptyList()), null, ShellConnectMode.AUTOMATIC).any { it.candidate == ShellCandidate.Iroh })
        assertFalse(ShellClient.schedule(credential.copy(addresses = emptyList(), irohID = "not-an-id"), null, ShellConnectMode.AUTOMATIC)
            .any { it.candidate == ShellCandidate.Iroh })
        // The discovered service is dialled first, like before.
        assertEquals(tcp("studio.local", 7893), ShellClient.schedule(cred, "studio.local" to 7893, ShellConnectMode.AUTOMATIC).first().candidate)
    }

    @Test fun connectModeStoredValues() {
        assertEquals(ShellConnectMode.AUTOMATIC, ShellConnectMode.fromStored(null))
        assertEquals(ShellConnectMode.AUTOMATIC, ShellConnectMode.fromStored("bogus"))
        assertEquals(ShellConnectMode.LOCAL_ONLY, ShellConnectMode.fromStored(ShellConnectMode.LOCAL_ONLY.stored))
        assertEquals("localOnly", ShellConnectMode.LOCAL_ONLY.stored)
        assertEquals("automatic", ShellConnectMode.AUTOMATIC.stored)
    }

    /**
     * A fake iroh dialer: [serve] plays the Mac on the far end of in-memory
     * pipes once it has read the phone's first line; with no [serve] the dial
     * hangs until [shutdown] (a Mac that can't be reached yet).
     */
    private inner class FakeIroh(private val path: ShellPath = ShellPath.RELAY, private val serve: ((FakeMac) -> Unit)? = null) : ShellIrohDialing {
        val dials = AtomicInteger()
        val shutdowns = AtomicInteger()
        val streamClosed = AtomicBoolean(false)
        val firstLine = LinkedBlockingQueue<ShellEnvelope>()
        @Volatile var dialed: List<String?> = emptyList()
        private val down = CompletableDeferred<Unit>()

        override suspend fun connect(irohID: String, relayURL: String?, relayToken: String?, addresses: List<String>): ShellIrohStream {
            dials.incrementAndGet()
            dialed = listOf(irohID, relayURL, relayToken) + addresses
            val serve = serve ?: run { down.await(); throw IOException("endpoint shut down") }
            val toMac = Pipe.open()
            val toPhone = Pipe.open()
            val mac = FakeMac(Channels.newInputStream(toMac.source()), Channels.newOutputStream(toPhone.sink()))
            macThread {
                firstLine.put(mac.receive())
                serve(mac)
            }
            cleanups += { toMac.source().close(); toPhone.sink().close() }
            return object : ShellIrohStream {
                override val input: InputStream = Channels.newInputStream(toPhone.source())
                override val output: OutputStream = Channels.newOutputStream(toMac.sink())
                override fun path() = this@FakeIroh.path
                override fun close() {
                    streamClosed.set(true)
                    runCatching { toPhone.source().close() }
                    runCatching { toMac.sink().close() }
                }
            }
        }

        override fun shutdown() {
            shutdowns.incrementAndGet()
            down.complete(Unit)
        }
    }

    private fun serveOnIroh(mac: FakeMac) {
        if (mac.handshake()) while (true) {
            val m = runCatching { mac.receive() }.getOrNull() ?: return
            if (m.t == ShellEnvelope.LIST) mac.send(ShellEnvelope(ShellEnvelope.SESSIONS, sessions = emptyList()))
        }
    }

    @Test fun irohWinsWhenTcpSilent() = runBlocking {
        val (silent, held) = silentServer()
        val iroh = FakeIroh(ShellPath.RELAY, ::serveOnIroh)
        val cred = credential.copy(addresses = emptyList(), irohID = irohID, irohRelay = "https://relay.example.com/", relayToken = "tok")
        val started = System.nanoTime()
        val connection = withTimeout(10_000) { ShellClient.connect(cred, "127.0.0.1" to silent, scope, iroh, ShellConnectMode.AUTOMATIC) }
        cleanups += { connection.close() }
        val elapsed = (System.nanoTime() - started) / 1_000_000
        assertTrue("iroh waits for the first TLS candidate ($elapsed ms)", elapsed >= ShellClient.IROH_DELAY_MS - 50)
        assertEquals(listOf(irohID, "https://relay.example.com/", "tok"), iroh.dialed)
        assertEquals("the phone says hello first on iroh", ShellEnvelope.HELLO, iroh.firstLine.poll(1, TimeUnit.SECONDS)?.t)
        val dialled = held.poll(1, TimeUnit.SECONDS)
        assertTrue("the silent address was dialled first", dialled != null)
        assertTrue("the losing TLS attempt is dropped", hungUp(dialled!!))

        val events = events(connection)
        assertEquals(ShellPath.RELAY, events.next<ShellEvent.Ready>().path)
        connection.list()
        assertEquals(emptyList<ShellSessionInfo>(), events.next<ShellEvent.Sessions>().sessions)
        assertEquals("the winner's endpoint stays up", 0, iroh.shutdowns.get())
        connection.close()
        assertTrue("closing the connection closes the iroh stream", iroh.streamClosed.get())
    }

    /** A TLS Mac that waits [delayMs] before challenging, then serves. */
    private fun slowTlsMac(delayMs: Long): Int = tlsServer { socket ->
        Thread.sleep(delayMs)
        serveMac(socket)
    }

    @Test fun irohLoserIsClosed() = runBlocking {
        // TLS answers after iroh has opened its stream (and said hello) but before iroh is ready.
        val port = slowTlsMac(1200)
        val iroh = FakeIroh(ShellPath.DIRECT) { mac -> runCatching { mac.receive() } }
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port,
            addresses = listOf("127.0.0.1"), irohID = irohID)
        val connection = withTimeout(10_000) { ShellClient.connect(cred, null, scope, iroh, ShellConnectMode.AUTOMATIC) }
        cleanups += { connection.close() }
        assertEquals(ShellEnvelope.HELLO, iroh.firstLine.poll(1, TimeUnit.SECONDS)?.t)
        assertEquals(ShellPath.LOCAL, events(connection).next<ShellEvent.Ready>().path)
        assertTrue("the losing iroh stream is closed", iroh.streamClosed.get())
        assertEquals("and its endpoint shut down", 1, iroh.shutdowns.get())
    }

    @Test fun irohStillDiallingIsShutDown() = runBlocking {
        val port = slowTlsMac(1200)
        val iroh = FakeIroh()
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port,
            addresses = listOf("127.0.0.1"), irohID = irohID)
        val connection = withTimeout(10_000) { ShellClient.connect(cred, null, scope, iroh, ShellConnectMode.AUTOMATIC) }
        cleanups += { connection.close() }
        assertEquals(1, iroh.dials.get())
        assertEquals(1, iroh.shutdowns.get())
        assertEquals(ShellPath.LOCAL, events(connection).next<ShellEvent.Ready>().path)
    }

    @Test fun localOnlyNeverDialsIroh() = runBlocking {
        val port = tlsServer(::serveMac)
        val iroh = FakeIroh(ShellPath.RELAY, ::serveOnIroh)
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port,
            addresses = listOf("127.0.0.1"), irohID = irohID)
        val connection = withTimeout(10_000) { ShellClient.connect(cred, null, scope, iroh, ShellConnectMode.LOCAL_ONLY) }
        cleanups += { connection.close() }
        assertEquals(0, iroh.dials.get())
        try {
            ShellClient.connect(cred.copy(addresses = emptyList()), null, scope, iroh, ShellConnectMode.LOCAL_ONLY)
            fail("expected noAddress")
        } catch (_: ShellConnectError.NoAddress) {
        }
    }

    @Test fun irohRefusalStopsEveryAttempt() = runBlocking<Unit> {
        val (silent, held) = silentServer()
        val iroh = FakeIroh { mac ->
            mac.send(ShellEnvelope(ShellEnvelope.CHALLENGE, nonce = b64(mac.nonce)))
            mac.receive()
            mac.send(ShellEnvelope(ShellEnvelope.ERROR, reason = ShellError.NOT_AUTHORIZED.wire))
        }
        val cred = credential.copy(addresses = emptyList(), irohID = irohID)
        val started = System.nanoTime()
        try {
            withTimeout(10_000) { ShellClient.connect(cred, "127.0.0.1" to silent, scope, iroh, ShellConnectMode.AUTOMATIC) }
            fail("expected a refusal")
        } catch (e: ShellConnectError.Refused) {
            assertEquals(ShellError.NOT_AUTHORIZED, e.reason)
        }
        assertTrue("a refusal over iroh doesn't wait for the silent address",
            (System.nanoTime() - started) / 1_000_000 < ShellClient.ATTEMPT_TIMEOUT_MS)
        held.poll(200, TimeUnit.MILLISECONDS)?.let { assertTrue("the TLS attempt is dropped", hungUp(it)) }
        assertTrue(iroh.streamClosed.get())
    }

    @Test fun noIrohCandidateWhenUnavailable() {
        val cred = credential.copy(irohID = irohID)
        assertFalse(ShellClient.schedule(cred, null, ShellConnectMode.AUTOMATIC, irohAvailable = false).any { it.candidate == ShellCandidate.Iroh })
        assertTrue(ShellClient.schedule(cred, null, ShellConnectMode.AUTOMATIC, irohAvailable = true).any { it.candidate == ShellCandidate.Iroh })
    }

    @Test fun irohAvailabilityLoadsOnceAndNeverThrows() {
        var loads = 0
        val broken = IrohAvailability { loads++; throw UnsatisfiedLinkError("dlopen failed") }
        assertFalse(broken.ensure())
        assertFalse(broken.ensure())
        assertEquals(1, loads)
        var ok = 0
        val working = IrohAvailability { ok++ }
        assertTrue(working.ensure())
        assertTrue(working.ensure())
        assertEquals(1, ok)
    }

    /** A native library that fails to link fails only the iroh candidate: TLS still connects, nothing crashes. */
    @Test fun irohLinkErrorFailsOnlyThatCandidate() = runBlocking {
        val port = slowTlsMac(1200)
        val iroh = object : ShellIrohDialing {
            val shutdowns = AtomicInteger()
            override suspend fun connect(irohID: String, relayURL: String?, relayToken: String?, addresses: List<String>): ShellIrohStream =
                throw UnsatisfiedLinkError("libiroh_ffi.so: dlopen failed")
            override fun shutdown() { shutdowns.incrementAndGet() }
        }
        val cred = credential.copy(certSHA256 = PinnedTls.fingerprint(testCertificate().encoded), port = port,
            addresses = listOf("127.0.0.1"), irohID = irohID)
        val connection = withTimeout(10_000) { ShellClient.connect(cred, null, scope, iroh, ShellConnectMode.AUTOMATIC) }
        cleanups += { connection.close() }
        assertEquals(ShellPath.LOCAL, events(connection).next<ShellEvent.Ready>().path)
        assertEquals(1, iroh.shutdowns.get())

        // With iroh the only candidate, the link error comes back as an ordinary failure.
        try {
            ShellClient.connect(cred.copy(addresses = emptyList()), null, scope, iroh, ShellConnectMode.AUTOMATIC)
            fail("expected a failure")
        } catch (e: IrohUnavailableException) {
            // (Coroutines may hand back a copy that wraps the original: look down the chain.)
            assertTrue(generateSequence<Throwable>(e) { it.cause }.any { it is UnsatisfiedLinkError })
        }
    }

    @Test fun irohWithoutADialerIsSkipped() = runBlocking {
        try {
            ShellClient.connect(credential.copy(addresses = emptyList(), irohID = irohID), null, scope, null, ShellConnectMode.AUTOMATIC)
            fail("expected noAddress")
        } catch (_: ShellConnectError.NoAddress) {
        }
    }

    @Test fun readyOverPipesIsLocal() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread { mac.handshake() }
        assertEquals(ShellPath.LOCAL, events.next<ShellEvent.Ready>().path)
    }

    @Test fun macInfoAfterReadySurfaces() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread {
            mac.handshake()
            mac.send(ShellEnvelope(ShellEnvelope.MAC_INFO, irohID = irohID, irohRelay = "https://relay.example.com/",
                relayToken = "tok-secret", addresses = listOf("192.168.1.9", "100.64.0.9")))
        }
        events.next<ShellEvent.Ready>()
        val info = events.next<ShellEvent.MacInfo>()
        assertEquals(irohID, info.irohID)
        assertEquals("https://relay.example.com/", info.irohRelay)
        assertEquals("tok-secret", info.relayToken)
        assertEquals(listOf("192.168.1.9", "100.64.0.9"), info.addresses)
        assertFalse("the relay token is never printed", info.toString().contains("tok-secret"))
    }

    @Test fun macInfoBeforeReadyIsAProtocolViolation() = runBlocking {
        val (connection, mac) = piped()
        val events = events(connection)
        macThread { mac.send(ShellEnvelope(ShellEnvelope.MAC_INFO, irohID = irohID)) }
        assertTrue(events.next<ShellEvent.Disconnected>().error is ShellConnectError.ProtocolViolation)
    }

    private companion object {
        val TEST_PASSWORD = "secret".toCharArray()
        /** Self-signed EC P-256 certificate and key (alias `mac`), for loopback TLS only. */
        const val TEST_P12 =
            "MIID6gIBAzCCA5QGCSqGSIb3DQEHAaCCA4UEggOBMIIDfTCCASQGCSqGSIb3DQEHAaCCARUEggERMIIBDTCCAQkGCyqGSIb3DQEMCgECoIG9MIG6MGYGCSqGSIb3DQEFDTBZMDgGCSqGSIb3DQEFDDArBBRU5EEf68zl9aXASlMSHSDWDHDtOgICJxACASAwDAYIKoZIhvcNAgkFADAdBglghkgBZQMEASoEEO5rE6cMinrKjL/nhfil9AkEUPSpTYArQ5/lCnuGg0jf73ilvb0QtVHKsBaJeAPssqB1rfXX/Yzd/jro8KT5Rf3MIU5XU4HkudRnqm98pPRWI9KMy1s7Wlh8vBBO8MRjaRIXMTowFQYJKoZIhvcNAQkUMQgeBgBtAGEAYzAhBgkqhkiG9w0BCRUxFAQSVGltZSAxNzkyNjMxMDc1MzkwMIICUQYJKoZIhvcNAQcGoIICQjCCAj4CAQAwggI3BgkqhkiG9w0BBwEwZgYJKoZIhvcNAQUNMFkwOAYJKoZIhvcNAQUMMCsEFA76EFXVdhEboO7m/fgNzUCIxwo3AgInEAIBIDAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQSBssqcjHaj0U/M/qH1wBgICCAcAC+NgQHxlHddY2ANJtW+cpi7xAkpj0xRrpl1nQsxbRM4RSq8Wz7F7Vr80BmGEVBdFQLEyRXmhJ9eL6TrIBlpflKbFIgLX8JGAwiuwtv3pp/G/+Cyhvb38lVECK10rVZa+VBHGigW3qB+hKWSjlSi8JCoOUyNp+juWNcYCGUPVZSFEac2f3O2v+QrpBwWdsqLnIzrnf88Q6HkS5D76n2q5R8n3DKxM/LQQNGFGB0JMSEIsPgGWq1TUQZGzXx3O47yCdVTKyR5RifIU0nrEVGcNW7+Bp+L9LIqKR8qCjBtHmHt+pjwSsxgsVd8eW37HJtW1wTaz+iMzFz7kPOz5tzYS6s7nnyZtxbGmLFvP/HV1qXEhrusEgJ+gN1JWgAsdvRAXkaZzUxqb+6qM0dF3ozW6bNpHVVSbwUv396peKv78X1JhSJLLxw5QI+T5qDC34PNxPWHX1us8OqyhI4hVwYzXLBWMs6r2UG/gkvAPoywhUNQJj4UN9uFD5oSpryTa8l98lwjh9FacibVWFR9eYFc9p9PTQFWhU6YBrpiwdW2yk5YXuQODGNhsJWXeY8F/iGC239ng8WKAV8+DZEeEqw9UrME0wMTANBglghkgBZQMEAgEFAAQgMu51g6F1Ku7jyRtRb6CoqUjzEDSmR4jiEV/fEG0PllIEFMANALGip5Hr605M6Pah4BN6r1LQAgInEA=="
    }
}
