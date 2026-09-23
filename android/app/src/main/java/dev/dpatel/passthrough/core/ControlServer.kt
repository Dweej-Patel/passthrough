package dev.dpatel.passthrough.core

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Newline-delimited JSON control channel: pairing, heartbeat, live status.
 * Mirrors PassthroughCore/ControlServer.swift message for message.
 */
class ControlServer(
    val port: Int = PassthroughProtocol.DEFAULT_CONTROL_PORT,
    private val socksPort: Int,
    private val registry: PairingRegistry,
    private val counter: ByteCounter,
    private val bindAddress: InetAddress = InetAddress.getLoopbackAddress(),
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
        // Status broadcast once a second to every authenticated Mac.
        ticker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "control-status").apply { isDaemon = true } }.also {
            it.scheduleWithFixedDelay({
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
        peers.toList().forEach { it.cancel() }
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
        ControlEnvelope.HELLO -> {
            if ((m.protocolVersion ?: 0) != PassthroughProtocol.VERSION) {
                listOf(ControlEnvelope(ControlEnvelope.ERROR, reason = PairingFailure.UNSUPPORTED_VERSION.wire))
            } else {
                val id = m.clientID
                val token = m.token
                var paired = false
                if (id != null && token != null && registry.verify(id, token)) {
                    paired = true
                    registry.touch(id)
                    peer.authenticate(id, m.name ?: "Mac")
                }
                listOf(welcome().apply { this.paired = paired })
            }
        }
        ControlEnvelope.PAIR -> {
            val id = m.clientID
            val code = m.code
            if (id == null || code == null) {
                listOf(ControlEnvelope(ControlEnvelope.ERROR, reason = PairingFailure.BAD_CODE.wire))
            } else when (val r = registry.pair(code, id, m.name ?: "Mac")) {
                is PairingRegistry.PairResult.Success -> {
                    peer.authenticate(id, m.name ?: "Mac")
                    listOf(
                        ControlEnvelope(ControlEnvelope.PAIRED, token = r.token, deviceName = statusProvider().deviceName, socksPort = socksPort),
                        statusMessage(),
                    )
                }
                is PairingRegistry.PairResult.Failure -> listOf(ControlEnvelope(ControlEnvelope.ERROR, reason = r.reason.wire))
            }
        }
        ControlEnvelope.PING -> listOf(ControlEnvelope(ControlEnvelope.PONG))
        else -> emptyList()
    }

    private fun welcome(): ControlEnvelope {
        val s = statusProvider()
        return ControlEnvelope(
            ControlEnvelope.WELCOME, protocolVersion = PassthroughProtocol.VERSION, deviceName = s.deviceName, socksPort = socksPort,
            radio = s.radio, carrier = s.carrier, battery = s.battery, hosting = s.hosting,
        )
    }

    private fun statusMessage(): ControlEnvelope {
        val s = statusProvider()
        val snap = counter.snapshot()
        return ControlEnvelope(
            ControlEnvelope.STATUS, deviceName = s.deviceName, radio = s.radio, carrier = s.carrier, battery = s.battery,
            hosting = s.hosting, activeConnections = snap.active, rxBytes = snap.rx, txBytes = snap.tx,
            timestamp = System.currentTimeMillis() / 1000.0,
        )
    }

    private inner class Peer(private val socket: Socket) {
        private val cancelled = AtomicBoolean(false)
        private lateinit var out: OutputStream
        @Volatile var mac: ConnectedMac? = null
            private set

        fun run() {
            try {
                socket.tcpNoDelay = true
                out = socket.getOutputStream()
                val input = socket.getInputStream()
                while (!cancelled.get()) {
                    val line = readLine(input) ?: break
                    if (line.isBlank()) continue
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

        /** Reads one newline-terminated line, capped so a peer can't balloon memory. */
        private fun readLine(input: InputStream): String? {
            val buf = ByteArrayOutputStream()
            while (true) {
                val b = input.read()
                if (b < 0) return null
                if (b == '\n'.code) return buf.toString(Charsets.UTF_8.name())
                buf.write(b)
                if (buf.size() > 256 * 1024) throw IOException("control line too long")
            }
        }

        fun authenticate(id: String, name: String) {
            if (mac == null) {
                mac = ConnectedMac(id, name, System.currentTimeMillis())
                ptLog(PtLog.Level.INFO, "$name connected over USB")
                onClientsChanged?.invoke(connectedMacs)
            }
        }

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
