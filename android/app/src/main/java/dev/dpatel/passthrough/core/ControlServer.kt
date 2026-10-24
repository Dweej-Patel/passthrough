package dev.dpatel.passthrough.core

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Base64
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Newline-delimited JSON control channel: pairing, heartbeat, live status.
 * Mirrors PassthroughCore/ControlServer.swift message for message. Any app on
 * the phone can connect to its loopback port, and anything on the Mac through
 * adb, so a connection is a stranger until the Mac proves its pairing (`auth`)
 * or pairs with the code shown; only then is it sent the phone's name and
 * status, or allowed to change anything. [unauthenticatedTimeoutMs] and [silenceLimitMs] are shorter in tests.
 */
class ControlServer(
    val port: Int = PassthroughProtocol.DEFAULT_CONTROL_PORT,
    private val socksPort: Int,
    private val registry: PairingRegistry,
    private val counter: ByteCounter,
    private val bindAddress: InetAddress = InetAddress.getLoopbackAddress(),
    private val unauthenticatedTimeoutMs: Long = PassthroughProtocol.UNAUTHENTICATED_TIMEOUT_MS,
    private val silenceLimitMs: Long = PassthroughProtocol.SILENCE_LIMIT_MS,
    private val statusProvider: () -> DeviceStatus,
) {
    @Volatile var onClientsChanged: ((List<ConnectedMac>) -> Unit)? = null
    private val peers = ConcurrentHashMap.newKeySet<Peer>()
    @Volatile private var serverSocket: ServerSocket? = null
    private var ticker: ScheduledExecutorService? = null
    @Volatile var isRunning = false
        private set

    val boundPort: Int get() = serverSocket?.localPort ?: port

    @Synchronized
    fun start() {
        if (isRunning) return
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(bindAddress, port), 16)
        serverSocket = ss
        isRunning = true
        Thread({ acceptLoop(ss) }, "control-accept").apply { isDaemon = true }.start()
        // Once a second: close peers that should go, then status to every authenticated Mac.
        ticker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "control-status").apply { isDaemon = true } }.also {
            it.scheduleWithFixedDelay({
                val now = System.currentTimeMillis()
                ArrayList(peers).forEach { p ->
                    closeReason(p, now)?.let { reason ->
                        ptLog(PtLog.Level.INFO, "Closing a control connection that $reason")
                        p.cancel()
                    }
                }
                val authenticated = peers.filter { p -> p.mac != null }
                if (authenticated.isNotEmpty()) {
                    val status = statusMessage()
                    authenticated.forEach { p -> p.send(listOf(status)) }
                }
            }, 1, 1, TimeUnit.SECONDS)
        }
        ptLog(PtLog.Level.INFO, "Control channel listening on port ${ss.localPort}")
    }

    @Synchronized
    fun stop() {
        if (!isRunning) return
        isRunning = false
        ticker?.shutdownNow(); ticker = null
        runCatching { serverSocket?.close() }
        serverSocket = null
        // A snapshot by toArray: toList() sizes the list first and can throw if a peer leaves meanwhile.
        ArrayList(peers).forEach { it.cancel() }
        peers.clear()
        onClientsChanged?.invoke(emptyList())
    }

    val connectedMacs: List<ConnectedMac> get() = peers.mapNotNull { it.mac }.sortedBy { it.since }

    private fun acceptLoop(ss: ServerSocket) {
        while (isRunning) {
            val socket = try { ss.accept() } catch (_: IOException) { break }
            if (peers.size >= 8) { runCatching { socket.close() }; continue }   // a handful of Macs, not a flood
            val peer = Peer(socket)
            peers.add(peer)
            Thread({ peer.run() }, "control-peer").apply { isDaemon = true }.start()
        }
    }

    // Message handling

    private fun handle(m: ControlEnvelope, peer: Peer): List<ControlEnvelope> = when (m.t) {
        ControlEnvelope.HELLO -> hello(m, peer)
        ControlEnvelope.AUTH -> auth(m, peer)
        ControlEnvelope.PAIR -> pair(m, peer)
        ControlEnvelope.SHELL_GRANT -> grantShell(m, peer)
        ControlEnvelope.PING -> listOf(ControlEnvelope(ControlEnvelope.PONG))
        else -> emptyList()
    }

    private fun hello(m: ControlEnvelope, peer: Peer): List<ControlEnvelope> {
        if (peer.hello != null) return emptyList()
        val version = m.protocolVersion ?: 0
        if (version != PassthroughProtocol.VERSION) {
            ptLog(PtLog.Level.WARNING, if (version < PassthroughProtocol.VERSION) "A Mac with an older Passthrough tried to connect: update Passthrough on the Mac"
                else "A Mac with a newer Passthrough tried to connect: update Passthrough on this phone")
            peer.reject()
            // Our version tells the Mac which side to update.
            return listOf(ControlEnvelope(ControlEnvelope.ERROR, reason = PairingFailure.UNSUPPORTED_VERSION.wire, protocolVersion = PassthroughProtocol.VERSION))
        }
        val id = m.clientID?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= 64 }
        val macNonce = ControlAuth.decodeNonce(m.nonce)
        if (id == null || macNonce == null) {
            peer.reject()
            return listOf(error(PairingFailure.NOT_AUTHENTICATED))
        }
        val phoneNonce = ControlAuth.nonce()
        peer.hello = Hello(id, (m.name ?: "Mac").take(64), macNonce, phoneNonce)
        val reply = welcome().apply { nonce = Base64.getEncoder().encodeToString(phoneNonce) }
        // Proving first gives nothing away: the proof is bound to the Mac's
        // fresh nonce and only says something to whoever holds K.
        val key = registry.pairingKey(id)
        reply.paired = key != null
        if (key != null) reply.proof = Base64.getEncoder().encodeToString(ControlAuth.phoneProof(key, id, macNonce, phoneNonce))
        return listOf(reply)
    }

    private fun auth(m: ControlEnvelope, peer: Peer): List<ControlEnvelope> {
        if (peer.mac != null) return emptyList()
        val hello = peer.hello
        val key = hello?.let { registry.pairingKey(it.clientID) }
        if (hello == null || key == null || !ControlAuth.isValidMacProof(m.proof, key, hello.clientID, hello.macNonce, hello.phoneNonce)) {
            ptLog(PtLog.Level.WARNING, "A Mac could not prove its pairing; closing its control connection")
            peer.reject()
            return listOf(error(PairingFailure.NOT_AUTHENTICATED))
        }
        registry.touch(hello.clientID)
        peer.authenticate(hello.clientID, hello.name)
        // The phone's status goes only to a proven Mac: the first now, not at the next tick.
        return listOf(statusMessage())
    }

    private fun pair(m: ControlEnvelope, peer: Peer): List<ControlEnvelope> {
        // After hello, which checked the version and named the Mac being paired.
        val hello = peer.hello ?: return listOf(error(PairingFailure.NOT_AUTHENTICATED))
        val code = m.code
        if (code == null || (m.clientID != null && m.clientID != hello.clientID)) return listOf(error(PairingFailure.BAD_CODE))
        return when (val r = registry.pair(code, hello.clientID, hello.name)) {
            is PairingRegistry.PairResult.Success -> {
                peer.authenticate(hello.clientID, hello.name)
                listOf(
                    ControlEnvelope(ControlEnvelope.PAIRED, token = r.token, deviceName = statusProvider().deviceName, socksPort = socksPort),
                    statusMessage(),
                )
            }
            is PairingRegistry.PairResult.Failure -> {
                if (r.reason != PairingFailure.BAD_CODE) return listOf(error(r.reason))
                // A few wrong codes per connection, then it is closed: a guesser must
                // keep reconnecting, and every guess still counts against the code
                // itself ([PairingRegistry.pair]), so opening many connections buys nothing.
                val wrong = peer.countWrongCode()
                if (wrong < PassthroughProtocol.PAIRING_MAX_WRONG_CODES_PER_CONNECTION) return listOf(error(PairingFailure.BAD_CODE))
                ptLog(PtLog.Level.WARNING, "Closing a control connection after $wrong wrong pairing codes")
                peer.reject()
                listOf(error(PairingFailure.LOCKED))
            }
        }
    }

    private fun error(failure: PairingFailure) = ControlEnvelope(ControlEnvelope.ERROR, reason = failure.wire)

    /** Why [peer] should be closed now, if it should: it was refused, has not proved a pairing in time, or (authenticated) went silent. */
    private fun closeReason(peer: Peer, now: Long): String? {
        if (peer.isRejected) return "was refused"
        if (peer.mac == null) {
            var deadline = peer.openedAt + unauthenticatedTimeoutMs
            // A Mac waiting for its user to type the code shown may wait as long as the code lasts.
            if (peer.hello != null) registry.activeCode?.let { deadline = maxOf(deadline, it.expiry) }
            return if (now > deadline) "did not prove a pairing in time" else null
        }
        return if (now - peer.lastHeard > silenceLimitMs) "stopped answering" else null
    }

    /** Only a Mac that already proved its pairing may be granted a shell; anything malformed is ignored. */
    private fun grantShell(m: ControlEnvelope, peer: Peer): List<ControlEnvelope> {
        val mac = peer.mac ?: return emptyList()
        val cert = m.certSHA256?.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F' } } ?: return emptyList()
        val key = m.shellKey?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }?.takeIf { it.size == 32 } ?: return emptyList()
        val port = m.shellPort?.takeIf { it in 1..65535 } ?: return emptyList()
        // The iroh details are all or nothing; bad ones never cost the LAN grant.
        val irohOk = IrohInfo.areValid(m.irohID, m.irohRelay, m.relayToken)
        if (!irohOk && (m.irohID != null || m.irohRelay != null || m.relayToken != null)) ptLog(PtLog.Level.INFO, "shell: ignoring invalid iroh info in grant")
        val irohID = m.irohID.takeIf { irohOk }
        val irohRelay = m.irohRelay.takeIf { irohOk }
        val relayToken = m.relayToken.takeIf { irohOk }
        val grant = ShellGrant(cert.lowercase(Locale.ROOT), port, (m.addresses ?: emptyList()).take(IrohInfo.MAX_ADDRESSES), (m.macName ?: mac.name).take(64),
            irohID, irohRelay)
        // The key is only ever kept sealed to the app's key. Before the app has made one, no
        // answer: the Mac keeps the key unrecorded and grants again later (with backoff, and on
        // every new cable connection).
        if (registry.shellSealingKey == null) {
            ptLog(PtLog.Level.INFO, "shell: open Passthrough once to set up Remote shell with ${mac.name}")
            return emptyList()
        }
        if (!registry.grantShell(mac.id, grant, key, relayToken)) {
            ptLog(PtLog.Level.ERROR, "Could not store the shell key from ${mac.name}")
            return emptyList()
        }
        ptLog(PtLog.Level.INFO, "Granted ${mac.name} a shell")
        // Echo the grant's name so the Mac records the key this answer is for.
        val grantID = m.grantID?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= ControlEnvelope.MAX_GRANT_ID_LENGTH }
        return listOf(ControlEnvelope(ControlEnvelope.SHELL_GRANTED, phoneID = registry.phoneID, grantID = grantID))
    }

    /**
     * Only what the handshake needs: whoever asks may be a stranger, so the phone's
     * name and status wait until the Mac has proved its pairing (the `status`
     * answering `auth`) or paired with the code (`paired`). The Mac already knows
     * the kind of phone from the cable, which is all its pairing prompt needs.
     */
    private fun welcome(): ControlEnvelope = ControlEnvelope(ControlEnvelope.WELCOME, protocolVersion = PassthroughProtocol.VERSION)

    private fun statusMessage(): ControlEnvelope {
        val s = statusProvider()
        val snap = counter.snapshot()
        return ControlEnvelope(
            ControlEnvelope.STATUS, deviceName = s.deviceName, radio = s.radio, carrier = s.carrier, battery = s.battery,
            hosting = s.hosting, ipv6 = s.ipv6, activeConnections = snap.active, rxBytes = snap.rx, txBytes = snap.tx,
            timestamp = System.currentTimeMillis() / 1000.0,
        )
    }

    /** What a Mac's hello said, and the nonce this connection's proofs use. */
    private class Hello(val clientID: String, val name: String, val macNonce: ByteArray, val phoneNonce: ByteArray)

    private inner class Peer(private val socket: Socket) {
        private val cancelled = AtomicBoolean(false)
        private lateinit var out: OutputStream
        /** Set once the Mac proved its pairing, or paired with the code. */
        @Volatile var mac: ConnectedMac? = null
            private set
        @Volatile var hello: Hello? = null
        val openedAt = System.currentTimeMillis()
        @Volatile var lastHeard = openedAt
            private set
        /** Answered with an error: nothing it sends counts any more, and the next tick closes it. */
        @Volatile var isRejected = false
            private set
        /** Wrong pairing codes sent on this connection (counted on its own reader thread). */
        private var wrongCodes = 0

        fun countWrongCode(): Int = ++wrongCodes

        fun run() {
            try {
                socket.tcpNoDelay = true
                out = socket.getOutputStream()
                val lines = LineReader(socket.getInputStream())
                while (!cancelled.get()) {
                    val line = lines.next() ?: break
                    if (line.isBlank() || isRejected) continue
                    lastHeard = System.currentTimeMillis()
                    val message = try { ControlEnvelope.decode(line) } catch (_: Exception) {
                        ptLog(PtLog.Level.WARNING, "control: undecodable message"); continue
                    }
                    send(handle(message, this))
                }
            } catch (_: IOException) {
            } finally {
                cancel()
            }
        }

        fun authenticate(id: String, name: String) {
            if (mac == null) {
                mac = ConnectedMac(id, name, System.currentTimeMillis())
                ptLog(PtLog.Level.INFO, "$name connected over USB")
                onClientsChanged?.invoke(connectedMacs)
            }
        }

        /** Closed at the next tick rather than now, so the error just sent gets out first. */
        fun reject() { isRejected = true }

        fun send(messages: List<ControlEnvelope>) {
            if (messages.isEmpty() || cancelled.get() || !this::out.isInitialized) return
            val payload = ByteArrayOutputStream()
            messages.forEach { payload.write(it.encodeLine()) }
            try {
                synchronized(this) { out.write(payload.toByteArray()); out.flush() }
            } catch (_: IOException) {
                cancel()
            }
        }

        fun cancel() {
            if (!cancelled.compareAndSet(false, true)) return
            runCatching { socket.close() }
            peers.remove(this)
            mac?.let { ptLog(PtLog.Level.INFO, "${it.name} disconnected") }
            onClientsChanged?.invoke(connectedMacs)
        }
    }
}
