package dev.dpatel.passthrough.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

/** Which ways a phone may dial its Mac's shell: a per-device setting. Mirrors ShellConnectMode in PassthroughCore. */
enum class ShellConnectMode(val stored: String) {
    /** Local network and Tailscale addresses, then iroh (from anywhere). */
    AUTOMATIC("automatic"),
    /** Local network and Tailscale addresses only. */
    LOCAL_ONLY("localOnly");

    companion object {
        /** The stored setting; anything unknown (or nothing) is [AUTOMATIC]. */
        fun fromStored(value: String?): ShellConnectMode = entries.firstOrNull { it.stored == value } ?: AUTOMATIC
    }
}

/** How the connection that reached `ready` is carried. Mirrors ShellPath in PassthroughCore. */
enum class ShellPath(
    /** How the shell card describes it; null for local/Tailscale and unknown paths. */
    val label: String?,
) {
    /** TLS over TCP: the local network, Tailscale or a typed address. */
    LOCAL(null),
    /** iroh, straight to the Mac (LAN or a hole-punched path). */
    DIRECT("direct"),
    /** iroh, through a relay. */
    RELAY("via relay"),
    /** iroh, path not known yet. */
    UNKNOWN(null),
}

/** One iroh stream to the Mac; closing it closes the connection and its endpoint. */
interface ShellIrohStream : Closeable {
    val input: InputStream
    val output: OutputStream
    /** How the stream is carried right now. */
    fun path(): ShellPath
}

/**
 * Dials the Mac over iroh for [ShellClient], so the race can be tested
 * without the native library (the app passes [IrohShellDialer]). Mirrors
 * ShellIrohDialing in PassthroughCore.
 */
interface ShellIrohDialing {
    /**
     * Connects to the Mac's endpoint [irohID] (through [relayURL], a custom
     * relay that may need [relayToken], or the default relays when null;
     * [addresses] are known direct "ip:port" sockets) and opens the shell's
     * stream. Nothing is written yet.
     */
    suspend fun connect(irohID: String, relayURL: String?, relayToken: String?, addresses: List<String>): ShellIrohStream
    /** Ends every dial in progress and closes the endpoints it bound. A later [connect] starts afresh. */
    fun shutdown()
}

/** iroh's native library could not be loaded or linked: only the iroh candidate fails. */
class IrohUnavailableException(cause: Throwable) : IOException("iroh: native library unavailable", cause)

/**
 * Whether iroh's native library is usable. [load] (installing the Android
 * context, which loads the library) runs once, the first time the shell
 * needs iroh, off the main thread; any failure, even an Error, is caught and
 * logged, and the shell then dials local and Tailscale addresses only.
 */
class IrohAvailability(private val load: () -> Unit) {
    private var result: Boolean? = null

    @Synchronized
    fun ensure(): Boolean = result ?: try {
        load()
        true
    } catch (e: Throwable) {
        ptLog(PtLog.Level.WARNING, "iroh: unavailable (${e.javaClass.simpleName})")
        false
    }.also { result = it }
}

/** One way to dial the Mac. */
sealed interface ShellCandidate {
    /** TLS to a discovered service or address. */
    data class Tcp(val host: String, val port: Int) : ShellCandidate
    /** iroh to the Mac's endpoint id. */
    data object Iroh : ShellCandidate
}

/** A candidate and when to dial it, in ms after the first. */
data class ShellDial(val candidate: ShellCandidate, val delayMs: Long)

/** What a [ShellConnection] reports. Mirrors ShellClient.Event in PassthroughCore. */
sealed interface ShellEvent {
    /** Authorized; commands are accepted. [path]: how, as known now. */
    data class Ready(val path: ShellPath = ShellPath.LOCAL) : ShellEvent
    /**
     * The Mac's current iroh details and addresses (sent after `ready`), for
     * the phone to keep with its grant. Never printed with its token.
     */
    data class MacInfo(val irohID: String?, val irohRelay: String?, val relayToken: String?, val addresses: List<String>?) : ShellEvent {
        override fun toString() = "MacInfo(irohID=$irohID, irohRelay=$irohRelay, relayToken=${if (relayToken == null) "none" else "<redacted>"}, addresses=$addresses)"
    }
    data class Sessions(val sessions: List<ShellSessionInfo>) : ShellEvent
    /** How the Mac is doing (after `ready`, and whenever it changes). */
    data class MacStateChanged(val state: MacState) : ShellEvent
    /** The answer to [ShellConnection.requestEvents]: what happened since then, oldest first, and the battery meanwhile. */
    data class Events(val since: Double, val events: List<MacEvent>, val battery: List<BatterySample>) : ShellEvent
    /** A session this connection opened, answering `open` [ref]; it is attached to it. */
    data class Opened(val session: String, val ref: Int? = null) : ShellEvent
    /** A session this connection opened after all, though an `attach` made before the Mac answered took its place: it runs detached. */
    data class OpenedDetached(val session: String) : ShellEvent
    class Output(val session: String, val data: ByteArray) : ShellEvent {
        override fun toString() = "Output(session=$session, ${data.size} bytes)"
    }
    /** The replay after an `attach` is complete; later output is live. */
    data class Attached(val session: String) : ShellEvent
    data class Ended(val session: String, val exitStatus: Int) : ShellEvent
    /** Another connection took the session over. */
    data class Detached(val session: String) : ShellEvent
    data class History(val entries: List<ShellHistoryEntry>) : ShellEvent
    /**
     * A piece of a transcript. [cols] and [rows], when set, are the size the
     * recorded terminal took here: [data] (and what follows) was drawn for it.
     */
    class Transcript(val session: String, val data: ByteArray, val done: Boolean, val cols: Int? = null, val rows: Int? = null) : ShellEvent {
        override fun toString() = "Transcript(session=$session, ${data.size} bytes, done=$done, size=${cols}x$rows)"
    }
    /** The Mac refused something; after `NOT_AUTHORIZED` during the handshake the connection closes. */
    /** [session] is the one the refused request named, if it named one. */
    /** [ref]: the `open` it refuses, if it does. */
    data class Failed(val error: ShellError, val session: String? = null, val ref: Int? = null) : ShellEvent
    /** The connection is gone (null: [ShellConnection.close] was called). Sent once. */
    data class Disconnected(val error: Throwable?) : ShellEvent
}

/**
 * How a ready connection that died without closing (the Mac asleep, a path
 * that dropped packets) is told from a quiet one: the phone pings the Mac
 * whenever it has heard nothing for [intervalMs], and gives the connection up
 * once it has heard nothing for [silenceMs]. Mirrors ShellClient.Liveness in
 * PassthroughCore, without its path probe: Android itself closes the sockets
 * of a network it lost.
 */
data class ShellLiveness(val intervalMs: Long = 5_000, val silenceMs: Long = 15_000)

/** Why a connection could not be made or ended. */
sealed class ShellConnectError(message: String) : IOException(message) {
    class NoAddress : ShellConnectError("no address to dial")
    class TimedOut : ShellConnectError("timed out")
    class ProtocolViolation(detail: String) : ShellConnectError("protocol violation: $detail")
    /** The Mac itself said no; every other address would get the same answer. */
    class Refused(val reason: ShellError) : ShellConnectError("refused: ${reason.wire}")
    class Closed : ShellConnectError("connection closed")
    /** A ready connection went silent: nothing from the Mac within [ShellLiveness]'s limits. */
    class StoppedAnswering : ShellConnectError("the Mac stopped answering")
}

/**
 * The phone's side of one shell connection (protocol/README.md, "Remote
 * shell") over already-open streams: answers the Mac's challenge, then talks
 * to one attached session at a time. Sockets and TLS live in [ShellClient], so
 * this runs over plain pipes in tests. Reading and writing happen on
 * [Dispatchers.IO] in children of [scope]; the methods below never block.
 *
 * [events] waits for a subscriber before delivering, so nothing is lost
 * between [ShellClient.connect] returning and the caller collecting.
 * Keys and terminal bytes are never logged.
 */
class ShellConnection(
    private val input: InputStream,
    private val output: OutputStream,
    private val credential: ShellCredential,
    private val scope: CoroutineScope,
    /** Closed with the connection (the socket under [input] and [output]). */
    private val closeable: Closeable? = null,
    /** Say `hello` first: on iroh the Mac waits for the phone's first line before it challenges. */
    hello: Boolean = false,
    /** How the connection is carried, read when it becomes ready. */
    private val path: () -> ShellPath = { ShellPath.LOCAL },
    private val liveness: ShellLiveness = ShellLiveness(),
) {
    private val _events = MutableSharedFlow<ShellEvent>(extraBufferCapacity = 64)
    /**
     * Collected once, by the app. An answer to an `open` is judged as it's delivered there, in
     * order with the app's own [attach] calls ([delivered]).
     */
    val events: Flow<ShellEvent> = _events.asSharedFlow().map(::delivered)

    private val lock = Any()
    private var active = true
    @Volatile private var ready = false
    private var challenged = false
    /** Commands made before `ready`, sent once it arrives. */
    private val queued = ArrayList<ShellEnvelope>()
    /** The session `input` goes to. */
    private var current: String? = null
    /** Sessions that ended or were taken over: an [ShellEvent.Opened] judged after that leaves nothing [current] (the Mac attached it, then lost it). */
    private val goneSessions = HashSet<String>()
    /**
     * Numbers `open`s (the Mac echoes the number in the answer). An `attach` overtakes every open
     * numbered up to [overtakenThrough]: the Mac attaches it after the sessions they make.
     * [answeredThrough] is the last whose answer the app has been given.
     */
    private var lastOpenRef = 0
    private var overtakenThrough = 0
    private var answeredThrough = 0
    /** When the last line from the Mac arrived ([System.nanoTime]). */
    @Volatile private var lastHeard = System.nanoTime()

    private val finished = AtomicBoolean(false)
    private val readyResult = CompletableDeferred<Unit>()
    private val outgoing = Channel<ShellEnvelope>(Channel.UNLIMITED)
    private val job = SupervisorJob(scope.coroutineContext[Job])
    private val io = CoroutineScope(scope.coroutineContext + job + Dispatchers.IO)

    init {
        if (hello) outgoing.trySend(ShellEnvelope(ShellEnvelope.HELLO))
        // The owner's scope ending hangs up too: blocking reads only end when the streams close.
        // (A watcher, not invokeOnCompletion: the job can't complete while a read blocks.)
        io.launch {
            try {
                awaitCancellation()
            } finally {
                if (finished.compareAndSet(false, true)) {
                    shutdown()
                    readyResult.completeExceptionally(ShellConnectError.Closed())
                }
            }
        }
        io.launch { writeLoop() }
        io.launch { readLoop() }
    }

    /** Returns once the Mac accepted the proof; throws why it didn't ([ShellConnectError.Refused] and others). */
    suspend fun awaitReady() = readyResult.await()

    fun list() = enqueue(ShellEnvelope(ShellEnvelope.LIST))

    fun open(cols: Int, rows: Int): Unit = synchronized(lock) {
        if (!active) return
        val ref = ++lastOpenRef
        enqueue(ShellEnvelope(ShellEnvelope.OPEN, cols = cols, rows = rows, ref = ref))
    }

    fun attach(session: String, cols: Int, rows: Int): Unit = synchronized(lock) {
        current = session
        overtakenThrough = lastOpenRef
        enqueue(ShellEnvelope(ShellEnvelope.ATTACH, session = session, cols = cols, rows = rows))
    }

    /** Keystrokes for the attached session, split into protocol-sized pieces. Dropped when none is attached. */
    fun input(bytes: ByteArray): Unit = synchronized(lock) {
        val session = current ?: return
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + RemoteShell.OUTPUT_CHUNK, bytes.size)
            enqueue(ShellEnvelope(ShellEnvelope.INPUT, session = session, data = b64(bytes.copyOfRange(offset, end))))
            offset = end
        }
    }

    /**
     * The terminal's size, for whatever session the Mac has attached when it
     * reads this, so also one an unanswered `open` is about to attach. It
     * names [current] only for Macs before that, which required it. Not sent
     * before `ready`: nothing is attached then, and `attach` carries the size.
     */
    fun resize(cols: Int, rows: Int): Unit = synchronized(lock) {
        if (!ready) return
        enqueue(ShellEnvelope(ShellEnvelope.RESIZE, session = current, cols = cols, rows = rows))
    }

    /** Ends a session on the Mac (its shell is hung up). */
    fun close(session: String) = enqueue(ShellEnvelope(ShellEnvelope.CLOSE, session = session))

    fun requestHistory() = enqueue(ShellEnvelope(ShellEnvelope.HISTORY))

    /** Asks the Mac to turn Keep awake on or off; the new state comes back as [ShellEvent.MacStateChanged]. */
    fun setAwake(on: Boolean) = enqueue(ShellEnvelope(ShellEnvelope.SET_AWAKE, on = on))

    /** As [setAwake], for the Mac's VPN. */
    fun setVPN(on: Boolean) = enqueue(ShellEnvelope(ShellEnvelope.SET_VPN, on = on))

    /** What happened on the Mac since [sinceSeconds] (Unix): [ShellEvent.Events], or `BAD_REQUEST` from an older Mac. */
    fun requestEvents(sinceSeconds: Double) = enqueue(ShellEnvelope(ShellEnvelope.EVENTS, since = kotlin.math.floor(sinceSeconds)))

    fun requestTranscript(session: String) = enqueue(ShellEnvelope(ShellEnvelope.TRANSCRIPT, session = session))

    /** Hangs up. Emits `Disconnected(null)` unless the connection had already ended. */
    fun close() {
        val first = finished.compareAndSet(false, true)
        if (first) {
            shutdown()
            readyResult.completeExceptionally(ShellConnectError.Closed())
        }
        job.cancel()
        if (first) scope.launch { _events.emit(ShellEvent.Disconnected(null)) }
    }

    // Internals

    private fun enqueue(message: ShellEnvelope) {
        synchronized(lock) {
            if (!active) return
            if (ready) outgoing.trySend(message) else queued += message
        }
    }

    private suspend fun writeLoop() {
        try {
            for (message in outgoing) {
                output.write(message.encodeLine())
                output.flush()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            finish(e)
        }
    }

    private suspend fun readLoop() {
        val lines = LineReader(input, RemoteShell.LINE_LIMIT)
        val error: Throwable = try {
            while (true) {
                val line = lines.next() ?: break
                lastHeard = System.nanoTime()
                handle(line)
                if (finished.get()) return
            }
            ShellConnectError.Closed()
        } catch (e: CancellationException) {
            throw e
        } catch (_: LineTooLongException) {
            ShellConnectError.ProtocolViolation("line too long")
        } catch (e: Exception) {
            e
        }
        finish(error)
    }

    private suspend fun handle(line: String) {
        val m = runCatching { ShellEnvelope.decode(line) }.getOrNull() ?: return
        if (!ready) {
            when {
                m.t == ShellEnvelope.CHALLENGE && !challenged -> {
                    val nonce = m.nonce?.let(::unb64)
                    if (nonce == null || nonce.size != 32) return finish(ShellConnectError.ProtocolViolation("bad challenge"))
                    challenged = true
                    val proof = ShellEnvelope(ShellEnvelope.PROOF, phoneID = credential.phoneID,
                        mac = b64(RemoteShell.proof(credential.shellKey, nonce)))
                    synchronized(lock) { if (active) outgoing.trySend(proof) }
                }
                m.t == ShellEnvelope.READY && challenged -> {
                    synchronized(lock) {
                        if (!active) return
                        ready = true
                        queued.forEach { outgoing.trySend(it) }
                        queued.clear()
                    }
                    readyResult.complete(Unit)
                    io.launch { heartbeat() }
                    emit(ShellEvent.Ready(runCatching(path).getOrDefault(ShellPath.UNKNOWN)))
                }
                m.t == ShellEnvelope.ERROR -> {
                    // Refused by the Mac itself: another address would get the same answer.
                    val reason = shellError(m.reason) ?: ShellError.NOT_AUTHORIZED
                    finish(ShellConnectError.Refused(reason), ShellEvent.Failed(reason, m.session))
                }
                else -> finish(ShellConnectError.ProtocolViolation("unexpected ${m.t}"))
            }
            return
        }
        when (m.t) {
            ShellEnvelope.MAC_INFO -> emit(ShellEvent.MacInfo(m.irohID, m.irohRelay, m.relayToken, m.addresses))
            ShellEnvelope.SESSIONS -> emit(ShellEvent.Sessions(m.sessions.orEmpty()))
            ShellEnvelope.MAC_STATE -> m.state?.let { emit(ShellEvent.MacStateChanged(it)) }
            ShellEnvelope.EVENT_LIST -> emit(ShellEvent.Events(m.since ?: 0.0, m.events.orEmpty(), m.battery.orEmpty()))
            ShellEnvelope.OPENED -> {
                val id = m.session ?: return
                emit(ShellEvent.Opened(id, m.ref))
            }
            ShellEnvelope.OUTPUT -> {
                val id = m.session ?: return
                val data = m.data?.let(::unb64) ?: return
                emit(ShellEvent.Output(id, data))
            }
            ShellEnvelope.ATTACHED -> emit(ShellEvent.Attached(m.session ?: return))
            ShellEnvelope.ENDED -> {
                val id = m.session ?: return
                synchronized(lock) {
                    if (current == id) current = null
                    goneSessions += id
                }
                emit(ShellEvent.Ended(id, m.exitStatus ?: -1))
            }
            ShellEnvelope.DETACHED -> {
                val id = m.session ?: return
                synchronized(lock) {
                    if (current == id) current = null
                    goneSessions += id
                }
                emit(ShellEvent.Detached(id))
            }
            ShellEnvelope.HISTORY_LIST -> emit(ShellEvent.History(m.history.orEmpty()))
            ShellEnvelope.TRANSCRIPT_DATA -> {
                val id = m.session ?: return
                val data = m.data?.let(::unb64) ?: return
                val sized = m.cols != null && m.rows != null && ShellReplay.isValid(m.cols!!, m.rows!!)
                emit(ShellEvent.Transcript(id, data, m.done ?: false, if (sized) m.cols else null, if (sized) m.rows else null))
            }
            ShellEnvelope.ERROR -> {
                val reason = shellError(m.reason) ?: ShellError.BAD_REQUEST
                // The Mac did not attach the session `attach` named: stop sending it input it would refuse.
                if (reason == ShellError.NO_SUCH_SESSION && m.session != null) {
                    synchronized(lock) { if (current == m.session) current = null }
                }
                emit(ShellEvent.Failed(reason, m.session, m.ref))
            }
            ShellEnvelope.PING -> enqueue(ShellEnvelope(ShellEnvelope.PONG))
            else -> Unit
        }
    }

    /**
     * While ready: pings a quiet Mac and gives up on a silent one. The Mac
     * answers every `ping` with `pong`, and any line it sends counts.
     */
    private suspend fun heartbeat() {
        while (true) {
            val quiet = (System.nanoTime() - lastHeard) / 1_000_000
            if (quiet >= liveness.silenceMs) return finish(ShellConnectError.StoppedAnswering())
            if (quiet >= liveness.intervalMs) enqueue(ShellEnvelope(ShellEnvelope.PING))
            delay(minOf(liveness.intervalMs, (liveness.silenceMs - quiet).coerceAtLeast(50)))
        }
    }

    /** Waits for a subscriber so events made before anyone collects aren't dropped. */
    private suspend fun emit(event: ShellEvent) {
        if (_events.subscriptionCount.value == 0) _events.subscriptionCount.first { it > 0 }
        _events.emit(event)
    }

    /** Ends the connection for good and says so once, after [before]. */
    private suspend fun finish(error: Throwable, before: ShellEvent? = null) {
        if (!finished.compareAndSet(false, true)) return
        shutdown()
        readyResult.completeExceptionally(error)
        before?.let { emit(it) }
        emit(ShellEvent.Disconnected(error))
        job.cancel()
    }

    /**
     * As [event] reaches the app: an `opened` whose open an `attach` since overtook arrives as
     * [ShellEvent.OpenedDetached]; otherwise input goes to its session.
     */
    private fun delivered(event: ShellEvent): ShellEvent = synchronized(lock) {
        when {
            event is ShellEvent.Opened -> {
                // A Mac that doesn't echo `ref` answers in order: count it as the latest (none
                // made yet: no attach can have overtaken it).
                val ref = event.ref ?: lastOpenRef
                answeredThrough = maxOf(answeredThrough, ref)
                if (ref != 0 && ref <= overtakenThrough) return@synchronized ShellEvent.OpenedDetached(event.session)
                current = if (event.session in goneSessions) null else event.session
                event
            }
            event is ShellEvent.Failed && event.ref != null -> {
                answeredThrough = maxOf(answeredThrough, event.ref)
                event
            }
            else -> event
        }
    }

    /** An `open` is unanswered, and no `attach` has overtaken it: its session will be the attached one. As of the events delivered so far. */
    val openPending: Boolean get() = synchronized(lock) { lastOpenRef > maxOf(answeredThrough, overtakenThrough) }

    private fun shutdown() {
        synchronized(lock) {
            active = false
            queued.clear()
            current = null
        }
        outgoing.close()
        runCatching { closeable?.close() }
        runCatching { input.close() }
        runCatching { output.close() }
    }

    private companion object {
        fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
        fun unb64(s: String): ByteArray? = try { Base64.getDecoder().decode(s) } catch (_: IllegalArgumentException) { null }
        fun shellError(wire: String?): ShellError? = ShellError.entries.firstOrNull { it.wire == wire }
    }
}

/**
 * Dials a Mac's shell: the discovered service first, then each granted
 * address, each over TLS pinned to the Mac's certificate with
 * [ATTEMPT_TIMEOUT_MS] to answer and authorize; and, in
 * [ShellConnectMode.AUTOMATIC] for a Mac that gave its iroh endpoint id, iroh
 * [IROH_DELAY_MS] after the first address (at once when there is none) with
 * [IROH_ATTEMPT_TIMEOUT_MS]. Addresses are dialled [STAGGER_MS] apart (the
 * next at once when one fails), so one that never answers does not hold up
 * one that does: the first to authorize wins and the rest are dropped.
 * Mirrors ShellClient.connect in PassthroughCore. Requires API 29+ (TLS 1.3).
 */
object ShellClient {
    /** How long one address gets to connect, handshake and authorize before it is given up. */
    const val ATTEMPT_TIMEOUT_MS = 4000
    /** The same for iroh, which may first have to reach a relay and punch a hole. */
    const val IROH_ATTEMPT_TIMEOUT_MS = 10_000L
    /** How long after one address the next is dialled. */
    const val STAGGER_MS = 250L
    /** iroh starts this long after the first address, so a local or Tailscale path that answers quickly is preferred. */
    const val IROH_DELAY_MS = 750L

    /** Where to dial: the discovered service first, then each granted address. */
    fun candidates(credential: ShellCredential, discovered: Pair<String, Int>?): List<Pair<String, Int>> {
        val granted = if (credential.port in 1..65535) credential.addresses.map { it to credential.port } else emptyList()
        return listOfNotNull(discovered) + granted
    }

    /**
     * When to dial each candidate: the TLS ones [STAGGER_MS] apart, and iroh
     * (in [ShellConnectMode.AUTOMATIC], for a Mac that gave a valid endpoint
     * id) [IROH_DELAY_MS] after the first of them, or at once when there are
     * none; never when iroh's native library is unavailable. Sorted; TLS
     * first on a tie.
     */
    fun schedule(credential: ShellCredential, discovered: Pair<String, Int>?, mode: ShellConnectMode, irohAvailable: Boolean = true): List<ShellDial> {
        val plan = candidates(credential, discovered).mapIndexed { i, (host, port) ->
            ShellDial(ShellCandidate.Tcp(host, port), i * STAGGER_MS)
        }.toMutableList()
        val id = credential.irohID
        if (!irohAvailable || mode != ShellConnectMode.AUTOMATIC || id == null || !IrohInfo.isValidID(id)) return plan
        val delay = if (plan.isEmpty()) 0L else IROH_DELAY_MS
        val at = plan.indexOfFirst { it.delayMs > delay }.takeIf { it >= 0 } ?: plan.size
        plan.add(at, ShellDial(ShellCandidate.Iroh, delay))
        return plan
    }

    /**
     * Dials the candidates on their [schedule] until one authorizes ([iroh]
     * null: TLS only). A refusal from the Mac ends every attempt
     * ([ShellConnectError.Refused]); otherwise throws the last attempt's
     * error, or [ShellConnectError.NoAddress].
     */
    suspend fun connect(
        credential: ShellCredential,
        discovered: Pair<String, Int>?,
        scope: CoroutineScope,
        iroh: ShellIrohDialing? = null,
        mode: ShellConnectMode = ShellConnectMode.AUTOMATIC,
        liveness: ShellLiveness = ShellLiveness(),
    ): ShellConnection {
        val plan = schedule(credential, discovered, mode, irohAvailable = iroh != null)
        if (plan.isEmpty()) throw ShellConnectError.NoAddress()
        return race(plan.map { it.candidate to it.delayMs }) { candidate, track ->
            val label = when (candidate) {
                is ShellCandidate.Tcp -> "shell: ${candidate.host}:${candidate.port}"
                ShellCandidate.Iroh -> "iroh: ${credential.macName}"
            }
            try {
                when (candidate) {
                    is ShellCandidate.Tcp -> attempt(candidate.host, candidate.port, credential, scope, liveness, track)
                    ShellCandidate.Iroh -> irohAttempt(credential, requireNotNull(iroh), scope, liveness, track)
                }
            } catch (e: ShellConnectError.Refused) {
                ptLog(PtLog.Level.WARNING, "shell: ${credential.macName} refused this phone (${e.reason.wire})")
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ptLog(PtLog.Level.INFO, "$label unreachable (${e.javaClass.simpleName})")
                throw e
            }
        }
    }

    /**
     * Runs [attempt] for each candidate at its delay (ms after the first;
     * the next one at once when an attempt fails). The first to succeed
     * wins; every other attempt is cancelled and whatever it handed to
     * `track` is run (closing its sockets, so blocking I/O ends too). A
     * [ShellConnectError.Refused] ends them all and is thrown; when every
     * attempt failed, the last failure is.
     */
    internal suspend fun <C, T> race(
        plan: List<Pair<C, Long>>,
        attempt: suspend (C, track: (() -> Unit) -> Unit) -> T,
    ): T = coroutineScope {
        val outcomes = Channel<Pair<Int, Result<T>>>(Channel.UNLIMITED)
        val failed = Channel<Unit>(Channel.CONFLATED)
        val trackers = List(plan.size) { Abandonable() }
        fun dropAllBut(keep: Int?) {
            trackers.forEachIndexed { i, t -> if (i != keep) t.abandon() }
            coroutineContext.job.cancelChildren()
        }
        launch {
            plan.forEachIndexed { i, (candidate, delayMs) ->
                val gap = if (i == 0) 0L else delayMs - plan[i - 1].second
                if (gap > 0) withTimeoutOrNull(gap) { failed.receive() }
                launch {
                    val result = try {
                        Result.success(attempt(candidate, trackers[i]::track))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Result.failure(e)
                    }
                    if (result.isFailure) failed.trySend(Unit)
                    outcomes.send(i to result)
                }
            }
        }
        var last: Throwable = ShellConnectError.NoAddress()
        try {
            repeat(plan.size) {
                val (i, result) = outcomes.receive()
                result.onSuccess { winner ->
                    dropAllBut(i)
                    return@coroutineScope winner
                }
                val error = result.exceptionOrNull()!!
                if (error is ShellConnectError.Refused) throw error
                last = error
            }
        } catch (e: Throwable) {
            dropAllBut(null)
            throw e
        }
        throw last
    }

    /** One attempt's sockets, closed if it loses (or is closed at once once it has). */
    private class Abandonable {
        private val closers = ArrayList<() -> Unit>()
        private var abandoned = false

        fun track(close: () -> Unit) {
            val now = synchronized(this) { abandoned.also { if (!it) closers += close } }
            if (now) runCatching(close)
        }

        fun abandon() {
            val pending = synchronized(this) {
                abandoned = true
                closers.toList().also { closers.clear() }
            }
            pending.forEach { runCatching(it) }
        }
    }

    /**
     * Dials iroh; once the stream is open, says `hello` (the Mac waits for the
     * phone's first line on iroh) and then answers the challenge as on TLS.
     * Losing or failing shuts the dialer's endpoint down; the winner's stream
     * owns its endpoint from then on.
     */
    private suspend fun irohAttempt(
        credential: ShellCredential,
        iroh: ShellIrohDialing,
        scope: CoroutineScope,
        liveness: ShellLiveness,
        track: (() -> Unit) -> Unit,
    ): ShellConnection {
        val irohID = credential.irohID ?: throw ShellConnectError.NoAddress()
        val down = AtomicBoolean(false)
        val shutdown = { if (down.compareAndSet(false, true)) iroh.shutdown() }
        track(shutdown)
        var stream: ShellIrohStream? = null
        var connection: ShellConnection? = null
        try {
            return withTimeoutOrNull(IROH_ATTEMPT_TIMEOUT_MS) {
                // The granted addresses are the TLS listener's hosts, without iroh's port:
                // iroh finds direct paths through the relay instead.
                val relayToken = credential.relayToken.takeIf { credential.irohRelay != null }
                val s = try {
                    iroh.connect(irohID, credential.irohRelay, relayToken, emptyList())
                } catch (e: LinkageError) {
                    // The native library failed to load or link (ExceptionInInitializerError too):
                    // this candidate fails like any other, the app carries on.
                    throw IrohUnavailableException(e)
                }
                stream = s
                track { s.close() }
                val c = ShellConnection(s.input, s.output, credential, scope, closeable = s, hello = true, path = s::path, liveness = liveness)
                connection = c
                track { c.close() }
                c.awaitReady()
                c
            } ?: throw ShellConnectError.TimedOut()
        } catch (e: Throwable) {
            connection?.close()
            runCatching { stream?.close() }
            shutdown()
            throw e
        }
    }

    private suspend fun attempt(
        host: String,
        port: Int,
        credential: ShellCredential,
        scope: CoroutineScope,
        liveness: ShellLiveness,
        track: (() -> Unit) -> Unit,
    ): ShellConnection {
        val started = System.nanoTime()
        var socket: SSLSocket? = null
        var connection: ShellConnection? = null
        try {
            withContext(Dispatchers.IO) {
                socket = PinnedTls.socket(host, port, credential.certSHA256, ATTEMPT_TIMEOUT_MS) { raw -> track { raw.close() } }
            }
            val s = requireNotNull(socket)
            val c = ShellConnection(s.inputStream, s.outputStream, credential, scope, closeable = s, liveness = liveness)
            connection = c
            track { c.close() }
            val left = ATTEMPT_TIMEOUT_MS - (System.nanoTime() - started) / 1_000_000L
            withTimeoutOrNull(left.coerceAtLeast(1)) { c.awaitReady() } ?: throw ShellConnectError.TimedOut()
            return c
        } catch (e: Throwable) {
            connection?.close()
            runCatching { socket?.close() }
            throw e
        }
    }
}
