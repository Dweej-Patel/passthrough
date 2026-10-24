package dev.dpatel.passthrough.ui.shell

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.dpatel.passthrough.BuildConfig
import dev.dpatel.passthrough.core.IrohInfo
import dev.dpatel.passthrough.core.IrohShellDialer
import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ShellClient
import dev.dpatel.passthrough.core.ShellConnectError
import dev.dpatel.passthrough.core.ShellConnectMode
import dev.dpatel.passthrough.core.ShellConnection
import dev.dpatel.passthrough.core.ShellCredential
import dev.dpatel.passthrough.core.ShellCredentials
import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.ShellEvent
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellKeyStatus
import dev.dpatel.passthrough.core.ShellPath
import dev.dpatel.passthrough.core.ShellReplay
import dev.dpatel.passthrough.core.ShellReplayChunk
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.core.ptLog
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.service.ShellDiscovery
import dev.dpatel.passthrough.service.ShellKeyVault
import dev.dpatel.passthrough.ui.lock.AppLock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * What a terminal view needs to hear, delivered synchronously on the main
 * thread and in protocol order. Mirrors ShellModel's subjects on iOS.
 */
interface ShellStreamListener {
    /** A session's output is about to start over (replay first when [replay]): clear. */
    fun streamStarting(session: String, replay: Boolean)
    fun output(session: String, data: ByteArray)
    /** The scrollback replay of an attach is complete; later output is live. */
    fun replayFinished(session: String)
}

/**
 * The phone's remote-shell state: which Macs granted the shell (keys from
 * [ShellKeyVault], read right after each unlock and then held only in
 * memory), the connection to the selected one, its sessions and history.
 * Mirrors iOS/App/Shell/ShellModel.swift. Lives as long as the activity's
 * view models, so connection events are always collected (a connection
 * nobody collects stops reading). Main-thread only. Keys and terminal bytes
 * are never logged.
 */
class ShellViewModel(app: Application) : AndroidViewModel(app) {
    private val vault: ShellKeyVault = Runtime.shellVault
    private val discovery = ShellDiscovery(app)

    private val _reach = MutableStateFlow(if (vault.supported) ShellReach.NO_ACCESS else ShellReach.UNSUPPORTED)
    val reach: StateFlow<ShellReach> = _reach.asStateFlow()
    private val _macs = MutableStateFlow<List<ShellCredential>>(emptyList())
    val macs: StateFlow<List<ShellCredential>> = _macs.asStateFlow()
    private val _selectedMacID = MutableStateFlow<String?>(null)
    val selectedMacID: StateFlow<String?> = _selectedMacID.asStateFlow()
    private val _sessions = MutableStateFlow<List<ShellSessionInfo>>(emptyList())
    val sessions: StateFlow<List<ShellSessionInfo>> = _sessions.asStateFlow()
    private val _history = MutableStateFlow<List<ShellHistoryEntry>>(emptyList())
    val history: StateFlow<List<ShellHistoryEntry>> = _history.asStateFlow()
    /** A history request is on its way to the Mac. */
    private val _historyLoading = MutableStateFlow(false)
    val historyLoading: StateFlow<Boolean> = _historyLoading.asStateFlow()
    private val _openTabs = MutableStateFlow<List<String>>(emptyList())
    val openTabs: StateFlow<List<String>> = _openTabs.asStateFlow()
    private val _activeSession = MutableStateFlow<String?>(null)
    val activeSession: StateFlow<String?> = _activeSession.asStateFlow()
    /** Sessions that have ended: their tabs show a read-only log of their output. */
    private val _ended = MutableStateFlow(ShellEndedSessions())
    val ended: StateFlow<ShellEndedSessions> = _ended.asStateFlow()
    /** The session another connection took over while this phone showed it; cleared on attach or open. */
    private val _detachedSession = MutableStateFlow<String?>(null)
    val detachedSession: StateFlow<String?> = _detachedSession.asStateFlow()
    /** The last thing the Mac refused (too many sessions…); cleared on the next connect or open. */
    private val _lastError = MutableStateFlow<ShellError?>(null)
    val lastError: StateFlow<ShellError?> = _lastError.asStateFlow()
    /** How the ready connection is carried, when known. */
    private val _path = MutableStateFlow<ShellPath?>(null)
    val path: StateFlow<ShellPath?> = _path.asStateFlow()
    /** Whether the current (or last) connect also tried iroh, for the unreachable copy. */
    private val _triedFromAnywhere = MutableStateFlow(false)
    val triedFromAnywhere: StateFlow<Boolean> = _triedFromAnywhere.asStateFlow()
    /** "Connect using": this device's choice. */
    val connectMode: StateFlow<ShellConnectMode> = Runtime.settings.shellConnectMode

    private val listeners = LinkedHashSet<ShellStreamListener>()

    private var lock: AppLock? = null
    /** Keys read from the vault since the last unlock, by Mac. */
    private var keys: Map<String, ByteArray> = emptyMap()
    private var connection: ShellConnection? = null
    private var connectJob: Job? = null
    private var clientMacID: String? = null
    /** Bumped per connection, so a replaced connection's late events are dropped. */
    private var generation = 0
    /**
     * A relock was requested because a key needed authentication; until a
     * refresh reads every key, another failure shows the copy instead of looping.
     */
    private var relockRequested = false
    private var foreground = true
    /** The Bonjour endpoint the current connect was given, to tell when a better one appears. */
    private var dialedDiscovered: Pair<String, Int>? = null
    private var size = 80 to 24
    private var pendingTranscript: PendingTranscript? = null
    private val refreshes = Channel<Unit>(Channel.CONFLATED)
    /** Debug builds only: the [ShellDemo] state shown instead of a real Mac (null normally). */
    private var demo: String? = null

    private class PendingTranscript(val id: String, val result: CompletableDeferred<List<ShellReplayChunk>?>) {
        val replay = ShellReplay.Collector()
    }

    init {
        // One refresh at a time, in order.
        viewModelScope.launch { for (r in refreshes) runRefresh() }
        // A grant or revoke from the cable (or Settings) while unlocked.
        viewModelScope.launch {
            Runtime.pairedClients.map { list -> list.map { it.id to it.shell } }.distinctUntilChanged().drop(1).collect {
                if (lock?.unlocked?.value == true) refresh()
            }
        }
        // Re-dial when the selected Mac shows up on Bonjour and the current attempt didn't have it.
        viewModelScope.launch {
            discovery.services.collect {
                if (_reach.value != ShellReach.UNREACHABLE && _reach.value != ShellReach.CONNECTING) return@collect
                val credential = current() ?: return@collect
                val found = ShellCredentials.discovered(it, credential.macName, _macs.value.size)?.endpoint ?: return@collect
                if (found != dialedDiscovered) connect()
            }
        }
        // "Connect using" changed: dial again with the new choice.
        viewModelScope.launch {
            connectMode.drop(1).collect { if (_macs.value.isNotEmpty() && foreground) connect() }
        }
    }

    /** Debug builds only (see [ShellDemo]): shows sample state; never dials. */
    fun startDemo(state: String) {
        if (!BuildConfig.DEBUG) return
        demo = state
        refresh()
    }

    fun addListener(listener: ShellStreamListener) { listeners += listener }
    fun removeListener(listener: ShellStreamListener) { listeners -= listener }

    // Lock and lifecycle

    /**
     * Right after each unlock, whose prompt opened the vault (Android 11+: its CryptoObject; Android 10:
     * the vault's 60 s window): adopt and read keys, then connect.
     */
    fun onUnlocked(lock: AppLock) {
        this.lock = lock
        foreground = true
        refresh()
    }

    /** The app lock closed: forget keys held in memory (the vault's too) and hang up. Tabs stay for the next unlock. */
    fun onLocked() {
        vault.lock()
        val granting = Runtime.pairedClients.value.any { it.shell != null }
        clear(ShellReach.beforeKeys(vault.supported, unlocked = false, deviceSecure = true, granting = granting) ?: ShellReach.LOCKED)
    }

    /** Leaving the foreground: sockets don't survive long in the background, so leave cleanly. */
    fun onBackground() {
        foreground = false
        dropConnection()
        discovery.stop()
        // Not usable until the foreground refresh dials again (typing meanwhile would go nowhere).
        if (_reach.value == ShellReach.READY) _reach.value = ShellReach.CONNECTING
    }

    /** Back in the foreground while unlocked: pick up new grants and reconnect. */
    fun onForeground() {
        foreground = true
        if (lock?.unlocked?.value == true) refresh()
    }

    // Credentials

    fun refresh() { refreshes.trySend(Unit) }

    private class Loaded(
        val clients: List<PairedClient>,
        val phoneID: String,
        val keys: Map<String, ByteArray>,
        val anyLocked: Boolean,
        val keyLost: Boolean,
        val deviceSecure: Boolean,
    )

    private suspend fun runRefresh() {
        val lock = lock ?: return
        if (!lock.unlocked.value) return
        demo?.let { return seedDemo(it) }
        val known = keys
        val loaded = withContext(Dispatchers.IO) { load(known) }
        // The lock may have closed meanwhile; its own handler cleared state.
        if (!lock.unlocked.value) return
        applyLoaded(loaded, lock)
    }

    /** Off the main thread: adopts pending keys and reads the ones not already in memory. */
    private fun load(known: Map<String, ByteArray>): Loaded {
        val registry = Runtime.registry
        val clients = registry.clients
        val granting = clients.filter { it.shell != null }
        if (!vault.supported || !vault.deviceSecure || granting.isEmpty()) {
            return Loaded(clients, "", emptyMap(), anyLocked = false, keyLost = false, deviceSecure = vault.deviceSecure)
        }
        vault.migrateLegacyLost(registry)
        var anyLocked = false
        val pending = granting.filter { registry.pendingShellKey(it.id) != null }.map { it.id }.toSet()
        if (pending.isNotEmpty()) {
            vault.adoptPending(registry)
            if (vault.status.value == ShellKeyStatus.LOCKED) anyLocked = true
        }
        vault.prune(clients.map { it.id }.toSet())
        val keys = HashMap<String, ByteArray>()
        for (client in granting) {
            val held = known[client.id]
            if (held != null && client.id !in pending) {
                keys[client.id] = held
                continue
            }
            when (val read = vault.read(client.id)) {
                is ShellKeyVault.Read.Key -> keys[client.id] = read.bytes
                ShellKeyVault.Read.Locked -> anyLocked = true
                ShellKeyVault.Read.Missing, ShellKeyVault.Read.Unavailable -> Unit
            }
        }
        // Per Mac: a Mac that granted again since the vault lost its key is not lost.
        val keyLost = granting.any { it.id !in keys && vault.isLost(it.id) }
        return Loaded(clients, registry.phoneID, keys, anyLocked, keyLost, deviceSecure = true)
    }

    private fun applyLoaded(loaded: Loaded, lock: AppLock) {
        val granting = loaded.clients.filter { it.shell != null }
        ShellReach.beforeKeys(vault.supported, unlocked = true, loaded.deviceSecure, granting.isNotEmpty())?.let { return clear(it) }
        if (loaded.anyLocked) {
            if (!relockRequested) {
                // The vault needs an unlock prompt (a grant arrived while the app was open and the vault
                // wasn't opened, or its 60 s window passed on Android 10): lock once, so the next
                // unlock adopts and reads it.
                relockRequested = true
                ptLog(PtLog.Level.INFO, "shell: key needs a fresh unlock; relocking")
                clear(ShellReach.LOCKED)
                lock.relock()
                return
            }
        } else {
            relockRequested = false
        }
        keys = loaded.keys
        val built = ShellCredentials.build(granting, loaded.phoneID, key = { keys[it] }, manualAddress = Runtime.settings::shellManualAddress,
            relayToken = Runtime.registry::relayToken)
        val previous = _macs.value.firstOrNull { it.macID == clientMacID }
        _macs.value = built
        if (built.none { it.macID == _selectedMacID.value }) _selectedMacID.value = built.firstOrNull()?.macID
        val current = current() ?: return clear(ShellReach.withoutCredential(granting.isNotEmpty(), loaded.anyLocked, loaded.keyLost))
        if (!foreground) return
        discovery.start()
        // Keep a live connection to the same Mac with the same key: a `macInfo` only
        // changed how to dial it next time. Otherwise dial again.
        val live = connection != null || connectJob?.isActive == true
        if (live && clientMacID == current.macID && previous != null) {
            if (_reach.value == ShellReach.READY && ShellCredentials.sameKey(previous, current)) return
            if (_reach.value == ShellReach.CONNECTING && previous == current) return
        }
        connect()
    }

    /** The user picked another Mac. */
    fun select(macID: String) {
        if (_selectedMacID.value == macID) return
        _selectedMacID.value = macID
        connect()
    }

    fun manualAddress(macID: String): String? = Runtime.settings.shellManualAddress(macID)

    /** Stores the address the user typed for a Mac; used from the next connect. */
    fun setManualAddress(macID: String, address: String) {
        Runtime.settings.setShellManualAddress(macID, address)
        val grant = Runtime.pairedClients.value.firstOrNull { it.id == macID }?.shell ?: return
        _macs.value = _macs.value.map {
            if (it.macID == macID) it.copy(addresses = ShellCredentials.addresses(grant.addresses, address)) else it
        }
    }

    // Connection

    private fun current(): ShellCredential? = _macs.value.firstOrNull { it.macID == _selectedMacID.value }

    /** Dials the selected Mac (replacing any connection); once ready, re-attaches (the Mac sends its sessions unasked). */
    fun connect() {
        if (demo != null) return refresh()
        dropConnection()
        val credential = current()
        if (credential == null) {
            if (_macs.value.isEmpty()) _reach.value = ShellReach.NO_ACCESS
            return
        }
        if (clientMacID != credential.macID) resetSessions()
        val gen = ++generation
        clientMacID = credential.macID
        _lastError.value = null
        _reach.value = ShellReach.CONNECTING
        val discovered = ShellCredentials.discovered(discovery.services.value, credential.macName, _macs.value.size)?.endpoint
        dialedDiscovered = discovered
        val mode = connectMode.value
        val wantsIroh = mode == ShellConnectMode.AUTOMATIC && credential.irohID?.let(IrohInfo::isValidID) == true
        _triedFromAnywhere.value = wantsIroh
        connectJob = viewModelScope.launch {
            val conn = try {
                // On IO: failed attempts close their sockets (TLS close_notify) where they fail,
                // and iroh's native library loads (once) off the main thread.
                withContext(Dispatchers.IO) {
                    val iroh = if (wantsIroh && Runtime.iroh.ensure()) {
                        // A fresh iroh endpoint (ephemeral key) per connect; the losing attempt or the winner's stream shuts it down.
                        IrohShellDialer()
                    } else {
                        null
                    }
                    if (wantsIroh && iroh == null && gen == generation) _triedFromAnywhere.value = false
                    ShellClient.connect(credential, discovered, viewModelScope, iroh, mode)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: ShellConnectError.Refused) {
                if (gen == generation) {
                    _lastError.value = e.reason
                    _reach.value = if (e.reason == ShellError.NOT_AUTHORIZED) ShellReach.NO_ACCESS else ShellReach.UNREACHABLE
                }
                return@launch
            } catch (_: Exception) {
                if (gen == generation) _reach.value = ShellReach.UNREACHABLE
                return@launch
            }
            if (gen != generation) {
                closeQuietly(conn)
            } else {
                connection = conn
            }
            // Collected until it ends, even once replaced: a connection nobody collects stops
            // reading and can't finish closing.
            conn.events.transformWhile { emit(it); it !is ShellEvent.Disconnected }.collect { event ->
                if (gen == generation) handle(event)
            }
        }
    }

    fun newSession(cols: Int, rows: Int) {
        size = cols to rows
        _lastError.value = null
        if (demo != null) {
            val id = "demo-new-${_openTabs.value.size}"
            handle(ShellEvent.Sessions(ShellDemo.sessions(listOf(id))))
            handle(ShellEvent.Opened(id))
            handle(ShellEvent.Output(id, ShellDemo.output(id)))
            return
        }
        connection?.open(cols, rows)
    }

    fun attach(id: String, cols: Int, rows: Int) {
        size = cols to rows
        if (id !in _openTabs.value) _openTabs.value = _openTabs.value + id
        _activeSession.value = id
        _detachedSession.value = null
        if (demo != null) return demoAttach(id)
        // Not connected yet: Ready attaches the active session, so asking now would replay twice.
        val conn = connection ?: return
        if (_reach.value != ShellReach.READY) return
        listeners.toList().forEach { it.streamStarting(id, true) }
        conn.attach(id, cols, rows)
    }

    fun send(data: ByteArray) {
        val active = _activeSession.value ?: return
        if (_ended.value.isEnded(active)) return
        connection?.input(data)
    }

    fun resize(cols: Int, rows: Int) {
        size = cols to rows
        connection?.resize(cols, rows)
    }

    /** Ends a running session on the Mac, or just closes the tab of an ended one (the Mac would refuse to close it again). */
    fun close(id: String) {
        if (!_ended.value.isEnded(id)) connection?.close(id)
        _ended.value = _ended.value.forget(id)
        _openTabs.value = _openTabs.value - id
        if (_activeSession.value == id) _activeSession.value = null
    }

    fun loadHistory() {
        if (demo != null) return handle(ShellEvent.History(ShellDemo.history()))
        val conn = connection ?: return
        _historyLoading.value = true
        conn.requestHistory()
    }

    /**
     * A session's saved transcript, with the terminal sizes it was drawn at (none
     * from an older Mac), or null without a connection, on refusal, or after 30 s.
     */
    suspend fun transcript(id: String): List<ShellReplayChunk>? {
        if (demo != null) return ShellDemo.transcript(id)
        val conn = connection ?: return null
        finishTranscript(null)
        val pending = PendingTranscript(id, CompletableDeferred())
        pendingTranscript = pending
        conn.requestTranscript(id)
        val result = withTimeoutOrNull(30_000) { pending.result.await() }
        if (pendingTranscript === pending) pendingTranscript = null
        return result
    }

    // Events

    private fun handle(event: ShellEvent) {
        when (event) {
            is ShellEvent.Ready -> {
                _reach.value = ShellReach.READY
                _path.value = event.path
                // No list(): the Mac sends `sessions` right after `ready`.
                // An ended session's log is already on screen; it has nothing more to send.
                _activeSession.value?.takeUnless { _ended.value.isEnded(it) }?.let { active ->
                    listeners.toList().forEach { it.streamStarting(active, true) }
                    connection?.attach(active, size.first, size.second)
                }
            }
            is ShellEvent.MacInfo -> apply(event)
            is ShellEvent.Sessions -> {
                _sessions.value = event.sessions
                val ids = event.sessions.map { it.id }.toSet()
                // The ended session on screen keeps its tab (and log) until the user closes it.
                val kept = _activeSession.value?.takeIf { _ended.value.isEnded(it) }
                _ended.value = _ended.value.apply(event.sessions, keeping = setOfNotNull(kept))
                _openTabs.value = _openTabs.value.filter { it in ids || it == kept }
                if (_activeSession.value?.let { it !in ids && it != kept } == true) _activeSession.value = null
                if (_detachedSession.value?.let { it !in ids } == true) _detachedSession.value = null
            }
            is ShellEvent.Opened -> {
                if (event.session !in _openTabs.value) _openTabs.value = _openTabs.value + event.session
                listeners.toList().forEach { it.streamStarting(event.session, false) }
                _activeSession.value = event.session
                _detachedSession.value = null
                _lastError.value = null
                connection?.list()
            }
            is ShellEvent.Output -> listeners.toList().forEach { it.output(event.session, event.data) }
            is ShellEvent.Attached -> listeners.toList().forEach { it.replayFinished(event.session) }
            is ShellEvent.Ended -> {
                _ended.value = _ended.value.ended(event.session, event.exitStatus)
                connection?.list()
            }
            is ShellEvent.Detached -> {
                // Another connection took it over; don't take it back on reconnect.
                if (_activeSession.value == event.session) {
                    _activeSession.value = null
                    _detachedSession.value = event.session
                }
            }
            is ShellEvent.History -> {
                _history.value = event.entries
                _historyLoading.value = false
            }
            is ShellEvent.Transcript -> {
                val pending = pendingTranscript ?: return
                if (pending.id != event.session) return
                pending.replay.add(event.data, event.cols, event.rows)
                if (event.done) finishTranscript(pending.replay.chunks())
            }
            is ShellEvent.Failed -> {
                _lastError.value = event.error
                if (event.error == ShellError.NOT_AUTHORIZED) _reach.value = ShellReach.NO_ACCESS
                // Only a failure naming the requested session ends that request.
                if ((event.error == ShellError.NO_SUCH_SESSION || event.error == ShellError.BAD_REQUEST) &&
                    event.session != null && event.session == pendingTranscript?.id) finishTranscript(null)
            }
            is ShellEvent.Disconnected -> {
                connection = null
                _path.value = null
                _historyLoading.value = false
                finishTranscript(null)
                if (event.error != null && _reach.value != ShellReach.NO_ACCESS) _reach.value = ShellReach.UNREACHABLE
            }
        }
    }

    // Private

    /**
     * Keeps what the connected Mac says about reaching it (iroh details,
     * addresses) with its grant, and uses it from the next connect. Never
     * touches the shell key; the live connection stays (see [applyLoaded]).
     */
    private fun apply(info: ShellEvent.MacInfo) {
        val credential = _macs.value.firstOrNull { it.macID == clientMacID } ?: return
        val gen = generation
        viewModelScope.launch {
            val manual = Runtime.settings.shellManualAddress(credential.macID)
            val updated = withContext(Dispatchers.IO) { ShellCredentials.applyMacInfo(Runtime.registry, credential, info, manual) } ?: return@launch
            if (gen != generation) return@launch
            _macs.value = _macs.value.map { if (it.macID == updated.macID && ShellCredentials.sameKey(it, updated)) updated else it }
        }
    }

    private fun finishTranscript(replay: List<ShellReplayChunk>?) {
        val pending = pendingTranscript ?: return
        pendingTranscript = null
        pending.result.complete(replay)
    }

    /** Ends the connection without touching tabs, so a later [connect] re-attaches. */
    private fun dropConnection() {
        generation++
        connectJob?.let { job -> if (connection == null) job.cancel() }
        connectJob = null
        connection?.let(::closeQuietly)
        connection = null
        _path.value = null
        _historyLoading.value = false
        finishTranscript(null)
    }

    /** close() does the TLS close_notify, which may block: never on the main thread. */
    private fun closeQuietly(conn: ShellConnection) {
        viewModelScope.launch(Dispatchers.IO) { conn.close() }
    }

    private fun resetSessions() {
        _sessions.value = emptyList()
        _history.value = emptyList()
        _openTabs.value = emptyList()
        _activeSession.value = null
        _detachedSession.value = null
        _ended.value = ShellEndedSessions()
    }

    /**
     * No usable Mac right now: forget keys held in memory and hang up. While
     * merely locked (or without a passcode) the selection and tabs stay, so the
     * next unlock reconnects and re-attaches.
     */
    private fun clear(reach: ShellReach) {
        dropConnection()
        keys = emptyMap()
        _macs.value = emptyList()
        if (reach == ShellReach.NO_ACCESS || reach == ShellReach.UNSUPPORTED) {
            discovery.stop()
            _selectedMacID.value = null
            clientMacID = null
            resetSessions()
        }
        _reach.value = reach
    }

    private fun seedDemo(state: String) {
        val reach = ShellDemo.reach(state)
        if (reach != ShellReach.READY) {
            _macs.value = if (reach == ShellReach.NO_ACCESS) emptyList() else ShellDemo.macs
            _selectedMacID.value = _macs.value.firstOrNull()?.macID
            _reach.value = reach
            return
        }
        _macs.value = ShellDemo.macs
        if (_selectedMacID.value == null) _selectedMacID.value = ShellDemo.macs.first().macID
        handle(ShellEvent.Ready(ShellDemo.path))
        handle(ShellEvent.Sessions(ShellDemo.sessions(_openTabs.value.filter { it.startsWith("demo-new") })))
        handle(ShellEvent.History(ShellDemo.history()))
    }

    private fun demoAttach(id: String) {
        listeners.toList().forEach { it.streamStarting(id, true) }
        handle(ShellEvent.Output(id, ShellDemo.output(id)))
        handle(ShellEvent.Attached(id))
        ShellDemo.ended(id)?.let(::handle)
    }

    override fun onCleared() {
        dropConnection()
        discovery.stop()
    }
}
