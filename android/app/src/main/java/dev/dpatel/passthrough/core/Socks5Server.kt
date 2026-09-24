package dev.dpatel.passthrough.core

import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * A SOCKS5 server that turns Mac-originated streams and datagrams into
 * connections opened by the phone's own network stack. Wire-compatible with
 * PassthroughCore/SOCKS5.swift: username/password auth (client ID + token),
 * CONNECT, and the "UDP in TCP" FORWARD_UDP command hev-socks5-tunnel uses.
 */
class Socks5Server(
    val config: Config = Config(),
    private val authenticator: ((user: String, password: String) -> Boolean)?,
    private val egress: EgressProvider = DefaultEgress,
) {
    data class Config(
        val port: Int = PassthroughProtocol.DEFAULT_SOCKS_PORT,
        /** Loopback only: the Mac reaches us through adb, never the radio. */
        val bindAddress: InetAddress = InetAddress.getLoopbackAddress(),
        val allowUDP: Boolean = true,
        val maxUdpPeersPerSession: Int = 512,
        /** How long a new connection may wait for a usable network before it fails. */
        val connectTimeoutMs: Int = 30_000,
        /** A client that never finishes the SOCKS handshake is dropped after this. */
        val handshakeTimeoutMs: Int = 20_000,
        val maxSessions: Int = 4096,
        /** Refuse private/link-local/multicast destinations (never reachable via the uplink). */
        val refuseLocalDestinations: Boolean = true,
    )

    val counter = ByteCounter()
    @Volatile var onAuthenticated: ((String) -> Unit)? = null
    private val threadIds = AtomicInteger()
    private val executor: ExecutorService = Executors.newCachedThreadPool { r ->
        Thread(r, "socks-${threadIds.incrementAndGet()}").apply { isDaemon = true }
    }
    private val sessions = ConcurrentHashMap.newKeySet<Session>()
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile var isRunning = false
        private set

    /** Port actually bound (useful when [Config.port] is 0 in tests). */
    val boundPort: Int get() = serverSocket?.localPort ?: config.port

    @Synchronized
    fun start() {
        if (isRunning) return
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(config.bindAddress, config.port), 128)
        serverSocket = ss
        isRunning = true
        Thread({ acceptLoop(ss) }, "socks-accept").apply { isDaemon = true }.start()
        ptLog(PtLog.Level.INFO, "SOCKS5 listening on port ${ss.localPort}")
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (isRunning) {
            val socket = try { ss.accept() } catch (_: IOException) { break }
            if (sessions.size >= config.maxSessions) {
                ptLog(PtLog.Level.WARNING, "SOCKS session cap reached (${config.maxSessions}); refusing")
                runCatching { socket.close() }
                continue
            }
            val session = Session(socket)
            sessions.add(session)
            try { executor.execute { session.run() } } catch (_: Exception) { session.close("executor stopped") }
        }
    }

    @Synchronized
    fun stop() {
        if (!isRunning) return
        isRunning = false
        runCatching { serverSocket?.close() }
        serverSocket = null
        sessions.toList().forEach { it.close("server stopped") }
        sessions.clear()
        ptLog(PtLog.Level.INFO, "SOCKS5 stopped")
    }

    val activeSessions: Int get() = sessions.size

    @Volatile private var lastDnsServer: InetAddress? = null

    /** Where a redirected DNS query goes on [egress]; logs when that changes. */
    private fun dnsServer(egress: Egress, address: Socks5.Address): InetAddress {
        val server = DnsRedirect.server(egress.dnsServers())
        if (server != lastDnsServer) {
            lastDnsServer = server
            ptLog(PtLog.Level.INFO, "DNS sent to ${address.host} goes to this phone's DNS server ${server.hostAddress} instead")
        }
        return server
    }

    private fun authenticate(user: String, password: String): Boolean {
        val auth = authenticator ?: return true
        val ok = auth(user, password)
        if (ok) onAuthenticated?.invoke(user)
        return ok
    }

    private inner class Session(private val client: Socket) {
        private val closed = AtomicBoolean(false)
        @Volatile private var remote: Socket? = null
        @Volatile private var udp: DatagramSocket? = null
        private var countedOpen = false
        private lateinit var input: DataInputStream
        private lateinit var output: OutputStream
        private var label = "remote"

        fun run() {
            try {
                client.tcpNoDelay = true
                client.soTimeout = config.handshakeTimeoutMs
                // Buffered on purpose, and reused for the payload afterwards:
                // clients may pipeline the greeting, auth and request.
                input = DataInputStream(BufferedInputStream(client.getInputStream(), 64 * 1024))
                output = client.getOutputStream()
                if (!greeting()) return
                request()
            } catch (_: EOFException) {
            } catch (_: SocketTimeoutException) {
                ptLog(PtLog.Level.DEBUG, "SOCKS handshake timeout")
            } catch (_: IOException) {
            } catch (e: Exception) {
                ptLog(PtLog.Level.WARNING, "SOCKS session error: ${e.javaClass.simpleName}: ${e.message}")
            } finally {
                close("done")
            }
        }

        private fun greeting(): Boolean {
            if (input.readUnsignedByte() != Socks5.VERSION) return false
            val methods = ByteArray(input.readUnsignedByte()).also { input.readFully(it) }.map { it.toInt() and 0xFF }
            if (authenticator != null) {
                if (Socks5.Method.PASSWORD !in methods) {
                    output.write(byteArrayOf(Socks5.VERSION.toByte(), Socks5.Method.UNACCEPTABLE.toByte())); return false
                }
                output.write(byteArrayOf(Socks5.VERSION.toByte(), Socks5.Method.PASSWORD.toByte()))
                if (input.readUnsignedByte() != 1) return false
                val user = ByteArray(input.readUnsignedByte()).also { input.readFully(it) }.toString(Charsets.UTF_8)
                val pass = ByteArray(input.readUnsignedByte()).also { input.readFully(it) }.toString(Charsets.UTF_8)
                if (!authenticate(user, pass)) {
                    ptLog(PtLog.Level.WARNING, "SOCKS auth rejected for client ${user.take(8)}")
                    output.write(byteArrayOf(1, 1)); return false
                }
                output.write(byteArrayOf(1, 0))
            } else {
                if (Socks5.Method.NONE !in methods) {
                    output.write(byteArrayOf(Socks5.VERSION.toByte(), Socks5.Method.UNACCEPTABLE.toByte())); return false
                }
                output.write(byteArrayOf(Socks5.VERSION.toByte(), Socks5.Method.NONE.toByte()))
            }
            return true
        }

        private fun request() {
            val head = ByteArray(4).also { input.readFully(it) }
            if (head[0].toInt() != Socks5.VERSION || head[2].toInt() != 0) return
            val cmd = head[1].toInt()
            val atyp = head[3].toInt()
            val body = when (atyp) {
                Socks5.AddressType.IPV4 -> ByteArray(6).also { input.readFully(it) }
                Socks5.AddressType.IPV6 -> ByteArray(18).also { input.readFully(it) }
                Socks5.AddressType.DOMAIN -> {
                    val len = input.readUnsignedByte()
                    byteArrayOf(len.toByte()) + ByteArray(len + 2).also { input.readFully(it) }
                }
                else -> { output.write(Socks5.reply(Socks5.Reply.ADDRESS_TYPE_NOT_SUPPORTED)); return }
            }
            val address = Socks5.Address.parse(byteArrayOf(atyp.toByte()) + body)
            if (address == null) { output.write(Socks5.reply(Socks5.Reply.ADDRESS_TYPE_NOT_SUPPORTED)); return }
            when {
                cmd == Socks5.Command.CONNECT -> {
                    if (config.refuseLocalDestinations && address.isLocalOnly) {
                        if (DnsRedirect.applies(address)) { connect(address, redirected = true); return }
                        ptLog(PtLog.Level.DEBUG, "refused $address: private/local address, not reachable via the phone")
                        output.write(Socks5.reply(Socks5.Reply.NETWORK_UNREACHABLE)); return
                    }
                    connect(address)
                }
                cmd == Socks5.Command.FORWARD_UDP && config.allowUDP -> forwardUdp()
                else -> output.write(Socks5.reply(Socks5.Reply.COMMAND_NOT_SUPPORTED))
            }
        }

        // CONNECT

        /** Opens the stream to [address], or to the phone's DNS server when [redirected] (see [DnsRedirect]). */
        private fun connect(address: Socks5.Address, redirected: Boolean = false) {
            label = address.toString()
            val deadline = System.currentTimeMillis() + config.connectTimeoutMs
            val eg = egress.acquire(config.connectTimeoutMs.toLong())
            if (eg == null) {
                ptLog(PtLog.Level.DEBUG, "connect to $address failed: no usable network")
                output.write(Socks5.reply(Socks5.Reply.NETWORK_UNREACHABLE)); return
            }
            val candidates = try {
                if (redirected) listOf(dnsServer(eg, address)) else address.ip?.let { listOf(it) } ?: eg.resolve(address.host)
            } catch (e: UnknownHostException) {
                ptLog(PtLog.Level.DEBUG, "connect to $address failed: DNS error")
                output.write(Socks5.reply(Socks5.Reply.HOST_UNREACHABLE)); return
            }
            var lastError: Exception? = null
            var socket: Socket? = null
            for ((i, ip) in candidates.withIndex()) {
                if (closed.get()) return
                val remaining = (deadline - System.currentTimeMillis()).toInt()
                if (remaining <= 0) break
                // Try later addresses (e.g. v4 after v6) before the whole budget is gone.
                val budget = if (i < candidates.size - 1) minOf(remaining, 8_000) else remaining
                val s = Socket()
                try {
                    eg.bind(s)
                    s.connect(InetSocketAddress(ip, address.port), budget)
                    socket = s
                    break
                } catch (e: Exception) {
                    lastError = e
                    runCatching { s.close() }
                    if (e is ConnectException && e.message?.contains("ECONNREFUSED") == true) break
                }
            }
            if (socket == null) {
                val code = replyCode(lastError)
                ptLog(PtLog.Level.DEBUG, "connect to $address failed: ${describe(lastError)}")
                output.write(Socks5.reply(code)); return
            }
            remote = socket
            if (closed.get()) { runCatching { socket.close() }; return }
            socket.tcpNoDelay = true
            socket.keepAlive = true
            client.soTimeout = 0
            countedOpen = true
            counter.connectionOpened()
            output.write(Socks5.reply(Socks5.Reply.SUCCEEDED))
            output.flush()
            val uploadDone = CountDownLatch(1)
            executor.execute {
                pump(input, socket.getOutputStream(), download = false) { runCatching { socket.shutdownOutput() } }
                uploadDone.countDown()
            }
            pump(socket.getInputStream(), output, download = true) { runCatching { client.shutdownOutput() } }
            // run() closes the session on return, so wait for the upload half too
            // (a failing pump closes both sockets, which ends the other one).
            uploadDone.await()
        }

        private fun pump(from: InputStream, to: OutputStream, download: Boolean, onEof: () -> Unit) {
            val buf = ByteArray(64 * 1024)
            try {
                while (!closed.get()) {
                    val n = from.read(buf)
                    if (n < 0) { onEof(); return }
                    if (n == 0) continue
                    to.write(buf, 0, n)
                    if (download) counter.addRx(n) else counter.addTx(n)
                }
            } catch (e: IOException) {
                if (!closed.get()) ptLog(PtLog.Level.DEBUG, "stream to $label ended: ${describe(e)}")
                close("stream error")
            }
        }

        // UDP over the stream

        private fun forwardUdp() {
            countedOpen = true
            counter.connectionOpened()
            client.soTimeout = 0
            output.write(Socks5.reply(Socks5.Reply.SUCCEEDED))
            output.flush()
            UdpRelay().run()
        }

        /**
         * One outbound UDP socket per forwarding session (one per Mac-side UDP
         * flow), so replies map back to the address the Mac asked for.
         */
        private inner class UdpRelay {
            /** Resolved endpoint → the raw SOCKS address the Mac used for it. */
            private val peers = object : LinkedHashMap<InetSocketAddress, ByteArray>(64, 0.75f, true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<InetSocketAddress, ByteArray>?) = size > config.maxUdpPeersPerSession
            }
            private val dns = HashMap<String, Pair<InetAddress, Long>>()

            fun run() {
                while (!closed.get()) {
                    val payloadLength = input.readUnsignedShort()
                    val headerLength = input.readUnsignedByte()
                    if (headerLength < 3 + 1 + 2) { close("bad udp frame"); return }
                    val addrRaw = ByteArray(headerLength - 3).also { input.readFully(it) }
                    val payload = ByteArray(payloadLength).also { input.readFully(it) }
                    val address = Socks5.Address.parse(addrRaw) ?: run { close("bad udp address"); return }
                    // Silently drop LAN/multicast probes; nothing on cellular can answer.
                    if (config.refuseLocalDestinations && address.isLocalOnly && !DnsRedirect.applies(address)) continue
                    counter.addTx(payload.size)
                    send(address, payload)
                }
            }

            private fun send(address: Socks5.Address, payload: ByteArray) {
                val target = try {
                    if (config.refuseLocalDestinations && DnsRedirect.applies(address)) {
                        val eg = egress.acquire(config.connectTimeoutMs.toLong()) ?: throw UnknownHostException(address.host)
                        InetSocketAddress(dnsServer(eg, address), DnsRedirect.PORT)
                    } else InetSocketAddress(address.ip ?: resolve(address.host), address.port)
                } catch (e: Exception) {
                    ptLog(PtLog.Level.DEBUG, "UDP to $address dropped: ${describe(e)}"); return
                }
                synchronized(peers) { peers[target] = address.raw }
                label = address.toString()
                val socket = socketOrNew() ?: return
                try {
                    socket.send(DatagramPacket(payload, payload.size, target))
                } catch (e: IOException) {
                    // The network under the socket went away (radio handoff, cellular
                    // fallback): replace it so later datagrams (DNS!) are not lost forever.
                    ptLog(PtLog.Level.DEBUG, "UDP to $address reset: ${describe(e)}")
                    resetSocket(socket)
                }
            }

            private fun resolve(host: String): InetAddress {
                val now = System.currentTimeMillis()
                dns[host]?.let { (ip, at) -> if (now - at < 60_000) return ip }
                val eg = egress.acquire(config.connectTimeoutMs.toLong()) ?: throw UnknownHostException(host)
                val ip = eg.resolve(host).first()
                if (dns.size > 256) dns.clear()
                dns[host] = ip to now
                return ip
            }

            @Synchronized
            private fun socketOrNew(): DatagramSocket? {
                udp?.let { if (!it.isClosed) return it }
                if (closed.get()) return null
                val eg = egress.acquire(config.connectTimeoutMs.toLong()) ?: return null
                val socket = DatagramSocket()
                try { eg.bind(socket) } catch (e: IOException) { socket.close(); return null }
                udp = socket
                executor.execute { receive(socket) }
                return socket
            }

            @Synchronized
            private fun resetSocket(socket: DatagramSocket) {
                socket.close()
                if (udp === socket) udp = null
            }

            private fun receive(socket: DatagramSocket) {
                val buf = ByteArray(65535)
                val packet = DatagramPacket(buf, buf.size)
                try {
                    while (!closed.get() && !socket.isClosed) {
                        packet.setData(buf, 0, buf.size)
                        try {
                            socket.receive(packet)
                        } catch (e: IOException) {
                            if (!closed.get() && !socket.isClosed) ptLog(PtLog.Level.DEBUG, "UDP receive ended: ${describe(e)}")
                            return
                        }
                        val from = packet.socketAddress as? InetSocketAddress ?: continue
                        var raw = synchronized(peers) { peers[from] } ?: Socks5.rawAddress(from.address, from.port)
                        if (3 + raw.size > 255) raw = Socks5.rawAddress(from.address, from.port)
                        val frame = Socks5.frameDatagram(raw, buf, packet.length)
                        try {
                            synchronized(output) { output.write(frame) }
                        } catch (_: IOException) {
                            close("udp client gone"); return
                        }
                        counter.addRx(packet.length)
                    }
                } finally {
                    resetSocket(socket)
                }
            }
        }

        fun close(reason: String) {
            if (!closed.compareAndSet(false, true)) return
            runCatching { client.close() }
            runCatching { remote?.close() }
            runCatching { udp?.close() }
            if (countedOpen) counter.connectionClosed()
            sessions.remove(this)
        }
    }

    companion object {
        fun replyCode(e: Exception?): Int {
            val msg = e?.message ?: ""
            return when {
                e is ConnectException && msg.contains("ECONNREFUSED") -> Socks5.Reply.CONNECTION_REFUSED
                e is ConnectException && msg.contains("refused", ignoreCase = true) -> Socks5.Reply.CONNECTION_REFUSED
                msg.contains("ENETUNREACH") || msg.contains("ENETDOWN") || msg.contains("Network is unreachable") -> Socks5.Reply.NETWORK_UNREACHABLE
                e is NoRouteToHostException || msg.contains("EHOSTUNREACH") -> Socks5.Reply.HOST_UNREACHABLE
                e is UnknownHostException -> Socks5.Reply.HOST_UNREACHABLE
                else -> Socks5.Reply.GENERAL_FAILURE
            }
        }

        /** Human wording for the errors that show up in the diagnostics log. */
        fun describe(e: Throwable?): String {
            val msg = e?.message ?: return "unknown error"
            return when {
                msg.contains("ECONNRESET") || msg.contains("Connection reset") -> "connection reset by the far end"
                e is SocketTimeoutException || msg.contains("ETIMEDOUT") -> "timed out"
                msg.contains("ECONNREFUSED") -> "connection refused"
                msg.contains("ENETDOWN") -> "network is down (cellular not available)"
                msg.contains("ENETUNREACH") -> "network unreachable"
                msg.contains("EHOSTUNREACH") -> "host unreachable"
                e is UnknownHostException -> "DNS error"
                else -> msg
            }
        }
    }
}
