package dev.dpatel.passthrough.core

import computer.iroh.BiStream
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointAddr
import computer.iroh.EndpointId
import computer.iroh.EndpointOptions
import computer.iroh.RelayConfig
import computer.iroh.RelayMap
import computer.iroh.RelayMode
import computer.iroh.presetMinimal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** The remote shell on iroh. Mirrors IrohShell in IrohTransport. */
object IrohShell {
    /** The remote shell's ALPN on iroh connections. */
    const val ALPN = "passthrough/shell/1"
}

/**
 * The phone's iroh dialer for [ShellClient]. Each [connect] binds a fresh
 * endpoint (an ephemeral key, never stored) with the minimal preset (no n0
 * DNS/pkarr, no mDNS) and the Mac's relay from the grant; [shutdown] closes
 * every endpoint it bound, ending dials in progress and their streams. A
 * stream that won owns its endpoint: closing it shuts the endpoint down.
 * Mirrors IrohShellDialer in IrohTransport. Needs
 * `IrohAndroid.installAndroidContext` first (PassthroughApp does it). Keys
 * and relay tokens are never logged.
 */
class IrohShellDialer : ShellIrohDialing {
    private val lock = Any()
    /** Bumped by [shutdown]: a dial that binds its endpoint after that closes it at once. */
    private var epoch = 0
    private val endpoints = ArrayList<Endpoint>()

    override suspend fun connect(irohID: String, relayURL: String?, relayToken: String?, addresses: List<String>): ShellIrohStream {
        val started = synchronized(lock) { epoch }
        // The Mac's relay (a custom one with its token, or its n0 home relay) is this
        // endpoint's relay too; none known: n0's defaults.
        val endpoint = try {
            Endpoint.bind(EndpointOptions(preset = presetMinimal(), relayMode = relayMode(relayURL, relayToken.takeIf { relayURL != null })))
        } catch (e: CancellationException) {
            throw e
        } catch (e: LinkageError) {
            throw IrohUnavailableException(e)
        } catch (e: Exception) {
            throw IOException("iroh: bind failed", e)
        }
        val active = currentCoroutineContext().isActive
        val current = synchronized(lock) {
            (epoch == started && active).also { if (it) endpoints += endpoint }
        }
        if (!current) {
            shutdownLater(endpoint)
            throw IOException("iroh: endpoint closed")
        }
        try {
            val address = EndpointAddr(EndpointId.fromString(irohID), relayURL, addresses)
            val connection = endpoint.connect(address, IrohShell.ALPN.toByteArray(Charsets.UTF_8))
            val stream = try {
                connection.openBi()
            } catch (e: Throwable) {
                runCatching { connection.close(0L, ByteArray(0)) }
                throw e
            }
            return IrohStream(endpoint, connection, stream) { release(it) }
        } catch (e: Throwable) {
            release(endpoint)
            if (e is CancellationException) throw e
            if (e is LinkageError) throw IrohUnavailableException(e)
            throw IOException("iroh: connect failed", e)
        }
    }

    override fun shutdown() {
        val closing = synchronized(lock) {
            epoch++
            endpoints.toList().also { endpoints.clear() }
        }
        closing.forEach(::shutdownLater)
    }

    /** Forgets and shuts down one endpoint (its stream closed, or its dial failed). */
    private fun release(endpoint: Endpoint) {
        val owned = synchronized(lock) { endpoints.remove(endpoint) }
        if (owned) shutdownLater(endpoint)
    }

    internal companion object {
        /** Endpoint shutdowns and stream drains run here, off the caller's thread. */
        val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private fun shutdownLater(endpoint: Endpoint) {
            cleanup.launch { runCatching { endpoint.shutdown() } }
        }

        /** A custom relay (with its token) as a single-relay map, or n0's defaults. */
        private fun relayMode(url: String?, token: String?): RelayMode {
            if (url == null) return RelayMode.defaultMode()
            val map = RelayMap.empty()
            map.insert(RelayConfig(url = url, authToken = token))
            return RelayMode.custom(map)
        }
    }
}

/**
 * One bidirectional QUIC stream of an iroh connection as blocking streams
 * (for [ShellConnection], which reads and writes on [Dispatchers.IO]).
 * Closing it stops new writes at once, then (off the caller's thread)
 * finishes the send half and waits up to [DRAIN_MS] for the Mac to
 * acknowledge what was sent, so the last keystrokes or a `close` aren't
 * dropped; then it closes the connection, which ends a blocked read, and the
 * endpoint via [released]. Mirrors IrohByteStream.cancel in IrohTransport.
 */
private class IrohStream(
    private val endpoint: Endpoint,
    private val connection: Connection,
    stream: BiStream,
    private val released: (Endpoint) -> Unit,
) : ShellIrohStream {
    private val send = stream.send()
    private val recv = stream.recv()
    private val closed = AtomicBoolean(false)

    override val input: InputStream = object : InputStream() {
        private var buffer = ByteArray(0)
        private var position = 0

        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (position >= buffer.size) {
                if (closed.get()) throw IOException("iroh: stream closed")
                val data = try {
                    runBlocking { recv.read(MAX_READ.toUInt()) }
                } catch (e: Exception) {
                    throw IOException("iroh: read failed", e)
                }
                // iroh returns an empty buffer once the peer has finished.
                if (data.isEmpty()) return -1
                buffer = data
                position = 0
            }
            val n = minOf(len, buffer.size - position)
            System.arraycopy(buffer, position, b, off, n)
            position += n
            return n
        }

        override fun close() = this@IrohStream.close()
    }

    override val output: OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (closed.get()) throw IOException("iroh: stream closed")
            if (len == 0) return
            try {
                runBlocking { send.writeAll(b.copyOfRange(off, off + len)) }
            } catch (e: Exception) {
                throw IOException("iroh: write failed", e)
            }
        }

        override fun close() = this@IrohStream.close()
    }

    override fun path(): ShellPath {
        val selected = connection.paths().firstOrNull { it.isSelected } ?: return ShellPath.UNKNOWN
        return when {
            selected.isRelay -> ShellPath.RELAY
            selected.isIp -> ShellPath.DIRECT
            else -> ShellPath.UNKNOWN
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        IrohShellDialer.cleanup.launch {
            withTimeoutOrNull(DRAIN_MS) {
                runCatching { send.finish() } // fails harmlessly if already finished or reset
                runCatching { send.stopped() }
            }
            runCatching { connection.close(0L, ByteArray(0)) }
            released(endpoint)
        }
    }

    private companion object {
        /** Largest single read (each read allocates this much in Rust). */
        const val MAX_READ = 65536
        /** How long closing waits for sent data to be acknowledged. */
        const val DRAIN_MS = 2000L
    }
}
