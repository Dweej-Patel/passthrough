package dev.dpatel.passthrough.ui.shell

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.dpatel.passthrough.BuildConfig
import dev.dpatel.passthrough.core.IrohInfo
import dev.dpatel.passthrough.core.IrohShellDialer
import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.MacTimeline
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
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
    /** Finished sessions removed from this phone, per Mac (the Mac keeps listing them for a while). */
    private var hiddenSessions = ShellHiddenSessions.stored(Runtime.settings.shellHiddenSessions())
    /**
     * What each Mac switched away from had said ended, in memory only: a remembered finished
     * tab can still be removed after switching back while that Mac is out of reach.
     */
    private val endedByMac = mutableMapOf<String, ShellEndedSessions>()
    private val _visibleSessions = MutableStateFlow<List<ShellSessionInfo>>(emptyList())
    /** The selected Mac's sessions minus the finished ones removed here; what lists and badges show. */
    val visibleSessions: StateFlow<List<ShellSessionInfo>> = _visibleSessions.asStateFlow()
    private val _history = MutableStateFlow<List<ShellHistoryEntry>>(emptyList())
    val history: StateFlow<List<ShellHistoryEntry>> = _history.asStateFlow()
    /** A history request is on its way to the Mac. */
    private val _historyLoading = MutableStateFlow(false)
    val historyLoading: StateFlow<Boolean> = _historyLoading.asStateFlow()
    private val _openTabs = MutableStateFlow<List<String>>(emptyList())
    val openTabs: StateFlow<List<String>> = _openTabs.asStateFlow()
    private val _activeSession = MutableStateFlow<String?>(null)
    val activeSession: StateFlow<String?> = _activeSession.asStateFlow()
    /**
     * Each Mac's open tabs and active tab, so switching back (or relaunching)
     * brings them back; kept in step with [openTabs]/[activeSession].
     */
    private val _tabMemory = MutableStateFlow(MacTabMemory.stored(Runtime.settings.shellTabMemory()))
    val tabMemory: StateFlow<MacTabMemory> = _tabMemory.asStateFlow()
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

    /** The selected Mac's state as it last said (kept while it can't be reached); null from an older Mac. */
    private val _macState = MutableStateFlow<MacState?>(null)
    val macState: StateFlow<MacState?> = _macState.asStateFlow()
    /** Keep awake and VPN changes the Mac doesn't show yet, one per switch (see [MacControls]). */
    private val _pendingControl = MutableStateFlow<List<MacControl>>(emptyList())
    val pendingControl: StateFlow<List<MacControl>> = _pendingControl.asStateFlow()
    /** Why the last Keep awake or VPN change didn't happen. */
    private val _controlError = MutableStateFlow<MacControlError?>(null)
    val controlError: StateFlow<MacControlError?> = _controlError.asStateFlow()
    private val controls = MacControls()
    private var controlTimer: Job? = null
    /** What happened on the selected Mac, as of the last [loadTimeline]. */
    private val _timeline = MutableStateFlow<MacTimeline?>(null)
    val timeline: StateFlow<MacTimeline?> = _timeline.asStateFlow()
    private val _timelineUnsupported = MutableStateFlow(false)
    val timelineUnsupported: StateFlow<Boolean> = _timelineUnsupported.asStateFlow()
    private var timelineLoading = false
    /** Whether the current (or last) connect also tried iroh, for the unreachable copy. */
    private val _triedFromAnywhere = MutableStateFlow(false)
    val triedFromAnywhere: StateFlow<Boolean> = _triedFromAnywhere.asStateFlow()
    /** Connecting again by itself after a working connection dropped (shown while [reach] is connecting). */
    private val _redialing = MutableStateFlow(false)
    val redialing: StateFlow<Boolean> = _redialing.asStateFlow()
    /** "Connect using": this device's choice. */
    val connectMode: StateFlow<ShellConnectMode> = Runtime.settings.shellConnectMode

    /** The other paired Macs' sessions and state, while the app is in the foreground and unlocked. */
    private val watcher = MacWatcher(
        viewModelScope,
        hiddenSessions = { hiddenSessions },
        discovered = { ShellCredentials.discovered(discovery.services.value, it.macName, _macs.value.size)?.endpoint },
        recency = { MacProfiles.recency(Runtime.settings.shellLastHeard(), Runtime.settings.shellLastSelectedAt()) },
        storedLastHeard = { Runtime.settings.shellLastHeard()[it] },
        noteHeard = ::noteHeard,
    )
    /** What each watched Mac (never the selected one) last said, by Mac ID. */
    val watchedMacs: StateFlow<Map<String, MacWatcher.Seen>> = watcher.seen
    /** A session on a Mac other than the selected one is waiting on a question. */
    val otherMacNeedsYou: StateFlow<Boolean> = combine(_macs, _selectedMacID, watcher.seen) { macs, selected, seen ->
        macs.any { it.macID != selected && otherStatus(it.macID, macs, seen) is MacStatus.Asking }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

    private val listeners = LinkedHashSet<ShellStreamListener>()

    private var lock: AppLock? = null
    /** Keys read from the vault since the last unlock, by Mac. */
    private var keys: Map<String, ByteArray> = emptyMap()
    /** What the last refresh learned about keys it couldn't use; read when [connect] selects a Mac without a credential. */
    private var keyFacts = ShellKeyFacts()
    private var connection: ShellConnection? = null
    private var connectJob: Job? = null
    private var clientMacID: String? = null
    /**
     * Set while tabs are cleared or restored for a Mac change: those aren't
     * changes the user made to the Mac whose tabs are showing.
     */
    private var holdingTabMemory = false

    /** The tabs showing; every change is remembered as the connected Mac's. */
    private var shownTabs: List<String>
        get() = _openTabs.value
        set(value) { _openTabs.value = value; rememberTabs() }
    private var shownActive: String?
        get() = _activeSession.value
        set(value) { _activeSession.value = value; rememberTabs() }
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
    /**
     * A working connection dropped (Wi-Fi lost, the Mac stopped answering):
     * how many redials have been made since. Null when not redialling.
     */
    private var redialsMade: Int? = null
    private var redialJob: Job? = null
    private var size = 80 to 24
    /**
     * A new session asked for while connecting (or waiting to redial): opened on Ready. Dropped
     * once the Mac can't be reached, or for another Mac or a tab chosen meanwhile.
     */
    private var openWhenReady = false
    /**
     * The active session wasn't (re-)attached because a new one was opening (on Ready, or a
     * terminal rebuilt meanwhile): re-attach it if that open is refused.
     */
    private var reattachIfRefused = false

    init {
        // Unreachable, no access, another Mac…: nobody is waiting for that new session any more.
        viewModelScope.launch {
            _reach.collect { if (it != ShellReach.CONNECTING && it != ShellReach.READY) openWhenReady = false }
        }
    }
    private var pendingTranscript: PendingTranscript? = null
    private val refreshes = Channel<Unit>(Channel.CONFLATED)
    /** Debug builds only: the [ShellDemo] state shown instead of a real Mac (null normally). */
    private var demo: String? = null
    private val _demoPaired = MutableStateFlow<List<PairedClient>>(emptyList())
    /** Debug demo only: the demo Macs standing in for paired ones in the switcher (empty in normal use). */
    val demoPaired: StateFlow<List<PairedClient>> = _demoPaired.asStateFlow()

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
        // "Connect using" changed: dial again with the new choice (connect() redials the watches first).
        viewModelScope.launch {
            connectMode.drop(1).collect { if (_macs.value.isNotEmpty() && foreground) connect() }
        }
    }

    /** Debug builds only (see [ShellDemo]): shows sample state; never dials. */
    fun startDemo(state: String) {
        if (!BuildConfig.DEBUG) return
        demo = state
        _demoPaired.value = if (ShellDemo.reach(state) == ShellReach.NO_ACCESS) emptyList()
        else ShellDemo.macs.map { PairedClient(it.macID, it.macName, "", 0) }
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
        stopRedialing()
        dropConnection()
        watcher.stop()
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
        val facts: ShellKeyFacts,
        val deviceSecure: Boolean,
    ) {
        val anyLocked: Boolean get() = facts.anyLocked
    }

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
        // At every unlock, so even a phone no Mac has granted yet can take the first grant sealed.
        if (vault.supported && vault.deviceSecure) vault.prepareSealing(registry)
        val clients = registry.clients
        val granting = clients.filter { it.shell != null }
        if (!vault.supported || !vault.deviceSecure || granting.isEmpty()) {
            return Loaded(clients, "", emptyMap(), ShellKeyFacts(granting.map { it.id }.toSet()), deviceSecure = vault.deviceSecure)
        }
        vault.migrateLegacyLost(registry)
        val locked = HashSet<String>()
        val pending = granting.filter { registry.sealedPendingShellKey(it.id) != null }.map { it.id }.toSet()
        if (pending.isNotEmpty()) {
            vault.adoptPending(registry)
            if (vault.status.value == ShellKeyStatus.LOCKED) locked += pending
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
                ShellKeyVault.Read.Locked -> locked += client.id
                ShellKeyVault.Read.Missing, ShellKeyVault.Read.Unavailable -> Unit
            }
        }
        // Per Mac: a Mac that granted again since the vault lost its key is not lost.
        val lost = granting.filter { it.id !in keys && vault.isLost(it.id) }.map { it.id }.toSet()
        val facts = ShellKeyFacts(granting.map { it.id }.toSet(), locked, lost)
        return Loaded(clients, registry.phoneID, keys, facts, deviceSecure = true)
    }

    private fun applyLoaded(loaded: Loaded, lock: AppLock) {
        // A Mac the phone forgot (one or all) takes its tabs and last-used mark with it.
        forgetUnpaired(loaded.clients.map { it.id }.toSet())
        val granting = loaded.clients.filter { it.shell != null }
        ShellReach.beforeKeys(vault.supported, unlocked = true, loaded.deviceSecure, granting.isNotEmpty())?.let { return clear(it, paired = loaded.clients.map { c -> c.id }) }
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
        keyFacts = loaded.facts
        val built = ShellCredentials.build(granting, loaded.phoneID, key = { keys[it] }, manualAddress = Runtime.settings::shellManualAddress,
            relayToken = Runtime.registry::relayToken)
        val previous = _macs.value.firstOrNull { it.macID == clientMacID }
        _macs.value = built
        // A paired Mac stays selected even without a shell credential (internet only).
        _selectedMacID.value = MacProfiles.selection(
            _selectedMacID.value, Runtime.settings.shellLastMac(), loaded.clients.map { it.id }, built.map { it.macID },
        )
        val current = current() ?: run {
            val mac = _selectedMacID.value
            if (mac == null) return clear(loaded.facts.reachWithoutCredential(null))
            updateWatcher()
            // A grant whose key can't be read keeps its recovery state; a Mac with no grant is internet only.
            return idleOnMacWithoutShell(loaded.facts.reachWithoutCredential(mac))
        }
        // Before any dial below: a watch on the (newly) selected Mac ends first. Also covers
        // the paths that keep the live connection (a new pairing changes what is watched).
        updateWatcher()
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

    /**
     * Makes [macID] the selected Mac: the only way the UI switches. The tabs
     * showing are kept for the Mac being left (nothing is sent to it), and the
     * new Mac's own tabs come back once [connect] dials it.
     */
    fun select(macID: String) {
        if (_selectedMacID.value == macID) return
        clientMacID?.let { _tabMemory.value = _tabMemory.value.save(MacTabs(_openTabs.value, _activeSession.value), it) }
        saveTabMemory()
        Runtime.settings.setShellLastMac(macID)
        Runtime.settings.setShellLastSelectedAt(Runtime.settings.shellLastSelectedAt() + (macID to System.currentTimeMillis()))
        _selectedMacID.value = macID
        // connect() ends the new Mac's watch before it dials.
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

    // Other Macs

    /** What a Mac's row in the switcher says: the selected Mac from the live connection, the others from their watch. */
    fun status(macID: String): MacStatus {
        if (macID != _selectedMacID.value) return otherStatus(macID, _macs.value, watcher.seen.value)
        return MacProfiles.status(_visibleSessions.value, reachable = _reach.value == ShellReach.READY,
            lastHeardMillis = Runtime.settings.shellLastHeard()[macID], hasShell = _macs.value.any { it.macID == macID })
    }

    private fun otherStatus(macID: String, macs: List<ShellCredential>, seen: Map<String, MacWatcher.Seen>): MacStatus {
        val watched = seen[macID]
        return MacProfiles.status(watched?.sessions, reachable = watched?.reachable ?: false,
            lastHeardMillis = watched?.lastHeardMillis ?: Runtime.settings.shellLastHeard()[macID],
            hasShell = macs.any { it.macID == macID })
    }

    /**
     * Starts or ends watches to match the paired Macs and the selection; ends them all while in
     * the background or locked (watches are foreground only). Runs on the main thread before every
     * live dial ([connect], [applyLoaded]), so the selected Mac's watch is retired first.
     */
    private fun updateWatcher() {
        if (demo != null) return applyDemoWatch()
        if (!foreground || lock?.unlocked?.value != true) return watcher.stop()
        // Android has no Live Activity: nothing is pinned.
        watcher.update(_macs.value, _selectedMacID.value, pinned = emptySet(), connectMode.value)
    }

    private fun noteHeard(macID: String, millis: Long) {
        Runtime.settings.setShellLastHeard(Runtime.settings.shellLastHeard() + (macID to millis))
    }

    // Connection

    private fun current(): ShellCredential? = _macs.value.firstOrNull { it.macID == _selectedMacID.value }

    /**
     * Dials the selected Mac (replacing any connection); once ready, re-attaches (the Mac sends its
     * sessions unasked). First of all, the watches are brought in line with the selection, so the
     * selected Mac's watch (if any) is ended before the live connection is started.
     */
    fun connect() {
        updateWatcher()
        if (demo != null) return refresh()
        dropConnection()
        redialJob?.cancel()
        redialJob = null
        val credential = current()
        if (credential == null) {
            stopRedialing()
            // Locked or without a passcode, a switch keeps that state: unlocking refreshes.
            // (`clear` reset the key facts, which would otherwise say "no access".)
            val reach = _reach.value
            if (reach == ShellReach.LOCKED || reach == ShellReach.NEEDS_PASSCODE) return
            // The same per-Mac key facts the last refresh used, so a locked or lost key keeps its recovery state.
            _selectedMacID.value?.let { mac -> return idleOnMacWithoutShell(keyFacts.reachWithoutCredential(mac)) }
            if (_macs.value.isEmpty()) _reach.value = ShellReach.NO_ACCESS
            return
        }
        if (clientMacID != credential.macID) switchSessions(credential.macID)
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
                    stopRedialing()
                    _lastError.value = e.reason
                    _reach.value = if (e.reason == ShellError.NOT_AUTHORIZED) ShellReach.NO_ACCESS else ShellReach.UNREACHABLE
                }
                return@launch
            } catch (_: Exception) {
                if (gen == generation) failed(dropped = false)
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
            val mac = _selectedMacID.value ?: return
            val prefix = ShellDemo.newPrefix(mac)
            val opened = _openTabs.value.filter { it.startsWith(prefix) }
            val id = generateSequence(1) { it + 1 }.map { "$prefix$it" }.first { it !in opened }
            handle(ShellEvent.Sessions(ShellDemo.sessions(mac, opened + id)))
            handle(ShellEvent.Opened(id))
            handle(ShellEvent.Output(id, ShellDemo.output(id)))
            return
        }
        val conn = connection
        if (conn == null || _reach.value != ShellReach.READY) {
            if (_reach.value == ShellReach.CONNECTING) openWhenReady = true
            return
        }
        conn.open(cols, rows)
    }

    /**
     * A rebuilt terminal (the phone rotated) shows the active session again: re-attached for its
     * replay, unless a new session is opening, which is shown when the Mac answers (an attach now
     * would overtake it).
     */
    fun resume(cols: Int, rows: Int) {
        if (openWhenReady || connection?.openPending == true) {
            size = cols to rows
            reattachIfRefused = _activeSession.value != null
            connection?.resize(cols, rows)
            return
        }
        _activeSession.value?.let { attach(it, cols, rows) }
    }

    fun attach(id: String, cols: Int, rows: Int) {
        size = cols to rows
        openWhenReady = false
        reattachIfRefused = false
        if (id !in _openTabs.value) shownTabs = _openTabs.value + id
        shownActive = id
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

    /**
     * Ends a running session on the Mac. A finished one is removed instead ([remove]): its tab
     * closes and it's hidden on this phone, since the Mac would refuse to close it again.
     */
    fun close(id: String) {
        if (hiddenSessions.canRemove(id, _ended.value, _sessions.value)) return remove(id)
        connection?.close(id)
        _ended.value = _ended.value.forget(id)
        shownTabs = _openTabs.value - id
        if (_activeSession.value == id) shownActive = null
    }

    /**
     * Removes a finished session from this phone: hides it for this Mac and
     * drops its tab. Never sends `close` (the Mac ignores it for a session that
     * has ended), so it works while the Mac is out of reach.
     */
    fun remove(id: String) {
        if (!hiddenSessions.canRemove(id, _ended.value, _sessions.value)) return
        (clientMacID ?: _selectedMacID.value)?.let {
            hiddenSessions = hiddenSessions.hide(id, it)
            saveHiddenSessions()
            publishVisible()
        }
        _ended.value = _ended.value.forget(id)
        shownTabs = _openTabs.value - id
        if (_activeSession.value == id) shownActive = null
    }

    /**
     * Asks the Mac to turn Keep awake or its VPN on or off; [macState] follows.
     * The caller asked for the biometric before VPN off. Made while the Mac
     * can't be reached (a PIN prompt stopped the activity, say), it's held and
     * sent once connected again, or given up after [MacControls.HOLD_MS].
     */
    fun control(change: MacControl) {
        if (demo != null) {
            _macState.value = _macState.value?.let {
                when (change) {
                    is MacControl.Awake -> it.copy(awake = change.on)
                    is MacControl.Vpn -> it.copy(vpn = if (change.on) MacStates.VPN_ON else MacStates.VPN_OFF)
                }
            }
            return
        }
        val conn = connection?.takeIf { _reach.value == ShellReach.READY }
        controls.request(change, ready = conn != null, SystemClock.elapsedRealtime())
        conn?.let { send(it, change) }
        publishControls()
    }

    private fun send(conn: ShellConnection, change: MacControl) = when (change) {
        is MacControl.Awake -> conn.setAwake(change.on)
        is MacControl.Vpn -> conn.setVPN(change.on)
    }

    /** Shows [controls]; while anything is pending, checks once a second for what to stop waiting on. */
    private fun publishControls() {
        _pendingControl.value = controls.pending
        _controlError.value = controls.error
        if (controls.pending.isEmpty() || controlTimer?.isActive == true) return
        controlTimer = viewModelScope.launch {
            while (controls.pending.isNotEmpty()) {
                delay(1_000)
                controls.expire(SystemClock.elapsedRealtime())
                _pendingControl.value = controls.pending
                _controlError.value = controls.error
            }
        }
    }

    /** Asks the Mac what happened since [sinceSeconds] (Unix); [timeline] follows. */
    fun loadTimeline(sinceSeconds: Double) {
        if (demo != null) {
            _timeline.value = ShellDemo.timeline(sinceSeconds)
            return
        }
        val conn = connection ?: return
        if (_reach.value != ShellReach.READY) return
        timelineLoading = true
        conn.requestEvents(sinceSeconds)
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
                stopRedialing()
                if (demo == null) clientMacID?.let { noteHeard(it, System.currentTimeMillis()) }
                _reach.value = ShellReach.READY
                _path.value = event.path
                connection?.let { conn -> controls.readied(SystemClock.elapsedRealtime()).forEach { send(conn, it) } }
                publishControls()
                // No list(): the Mac sends `sessions` right after `ready`.
                // An ended session's log is already on screen; it has nothing more to send.
                val active = _activeSession.value?.takeUnless { _ended.value.isEnded(it) }
                if (openWhenReady) {
                    // Not the active one first: it would take the keystrokes meant for the new one
                    // until the Mac answers.
                    openWhenReady = false
                    reattachIfRefused = active != null
                    connection?.open(size.first, size.second)
                } else if (active != null) {
                    reattachIfRefused = false
                    listeners.toList().forEach { it.streamStarting(active, true) }
                    connection?.attach(active, size.first, size.second)
                }
            }
            is ShellEvent.MacInfo -> apply(event)
            is ShellEvent.MacStateChanged -> {
                _macState.value = event.state
                controls.stateArrived(event.state)
                publishControls()
            }
            is ShellEvent.Events -> {
                _timeline.value = MacTimeline(event.since, event.events, event.battery, System.currentTimeMillis() / 1000.0)
                _timelineUnsupported.value = false
                timelineLoading = false
            }
            is ShellEvent.Sessions -> {
                _sessions.value = event.sessions
                val ids = event.sessions.map { it.id }.toSet()
                (clientMacID ?: _selectedMacID.value)?.let {
                    val applied = hiddenSessions.apply(ids.toList(), it)
                    if (applied != hiddenSessions) { hiddenSessions = applied; saveHiddenSessions() }
                }
                publishVisible()
                // The ended session on screen keeps its tab (and log) until the user closes it.
                val kept = _activeSession.value?.takeIf { _ended.value.isEnded(it) }
                _ended.value = _ended.value.apply(event.sessions, keeping = setOfNotNull(kept))
                shownTabs = _openTabs.value.filter { it in ids || it == kept }
                if (_activeSession.value?.let { it !in ids && it != kept } == true) shownActive = null
                if (_detachedSession.value?.let { it !in ids } == true) _detachedSession.value = null
            }
            is ShellEvent.Opened -> {
                if (event.session !in _openTabs.value) shownTabs = _openTabs.value + event.session
                reattachIfRefused = false
                listeners.toList().forEach { it.streamStarting(event.session, false) }
                shownActive = event.session
                _detachedSession.value = null
                _lastError.value = null
                connection?.list()
            }
            is ShellEvent.OpenedDetached -> {
                // The user went to another tab before the Mac answered: the new one waits beside it,
                // and the tab on screen stays.
                if (event.session !in _openTabs.value) shownTabs = _openTabs.value + event.session
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
                    shownActive = null
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
                // A refused open: unless another is coming (re-attaching would overtake it).
                if (event.ref != null && reattachIfRefused && connection?.openPending == false) {
                    reattachIfRefused = false
                    _activeSession.value?.let { attach(it, size.first, size.second) }
                }
                if (event.error == ShellError.NOT_ALLOWED || event.error == ShellError.VPN_NOT_SET_UP) {
                    controls.refused(event.error)
                    publishControls()
                    return
                }
                if (event.error == ShellError.BAD_REQUEST && event.session == null && event.ref == null && timelineLoading) {
                    timelineLoading = false
                    _timelineUnsupported.value = true
                    return
                }
                _lastError.value = event.error
                if (event.error == ShellError.NOT_AUTHORIZED) _reach.value = ShellReach.NO_ACCESS
                // Only a failure naming the requested session ends that request.
                if ((event.error == ShellError.NO_SUCH_SESSION || event.error == ShellError.BAD_REQUEST) &&
                    event.session != null && event.session == pendingTranscript?.id) finishTranscript(null)
            }
            is ShellEvent.Disconnected -> {
                val dropped = _reach.value == ShellReach.READY
                if (dropped) clientMacID?.let { noteHeard(it, System.currentTimeMillis()) }
                connection = null
                reattachIfRefused = false
                _path.value = null
                _historyLoading.value = false
                timelineLoading = false
                controls.disconnected()
                publishControls()
                finishTranscript(null)
                if (event.error != null && _reach.value != ShellReach.NO_ACCESS) failed(dropped)
            }
        }
    }

    // Private

    /**
     * A connect failed, or a working connection dropped ([dropped]): after a
     * drop, dial again on [REDIAL_DELAYS_MS] (showing Reconnecting; the open
     * session re-attaches once ready, as on any connect). Unreachable, with
     * Try again, once they run out or when not redialling.
     */
    private fun failed(dropped: Boolean) {
        if (dropped) redialsMade = 0
        val made = redialsMade
        if (made == null || made >= REDIAL_DELAYS_MS.size || !foreground) {
            stopRedialing()
            _reach.value = ShellReach.UNREACHABLE
            return
        }
        redialsMade = made + 1
        _redialing.value = true
        _reach.value = ShellReach.CONNECTING
        redialJob?.cancel()
        redialJob = viewModelScope.launch {
            delay(REDIAL_DELAYS_MS[made])
            redialJob = null
            // Dropped if something else connected, locked or cleared meanwhile.
            if (_reach.value == ShellReach.CONNECTING && connection == null && foreground) connect()
        }
    }

    private fun stopRedialing() {
        redialJob?.cancel()
        redialJob = null
        redialsMade = null
        _redialing.value = false
    }

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
        // Remember when the Mac being left last answered, for "last heard".
        if (_reach.value == ShellReach.READY && demo == null) clientMacID?.let { noteHeard(it, System.currentTimeMillis()) }
        generation++
        connectJob?.let { job -> if (connection == null) job.cancel() }
        connectJob = null
        connection?.let(::closeQuietly)
        connection = null
        reattachIfRefused = false
        _path.value = null
        _historyLoading.value = false
        timelineLoading = false
        controls.disconnected()
        publishControls()
        finishTranscript(null)
    }

    /** close() does the TLS close_notify, which may block: never on the main thread. */
    private fun closeQuietly(conn: ShellConnection) {
        viewModelScope.launch(Dispatchers.IO) { conn.close() }
    }

    /**
     * The selected Mac is paired but has no usable shell credential: internet only ([reach] NO_ACCESS), or
     * a grant whose key can't be read (its recovery state). Nothing of the Mac left (sessions, tabs,
     * state) shows, and no tabs are restored or saved for this one: [clientMacID] is null, so the next
     * dial with a credential restores its remembered tabs.
     */
    private fun idleOnMacWithoutShell(reach: ShellReach) {
        stopRedialing()
        dropConnection()
        resetSessions()
        clientMacID = null
        _lastError.value = null
        _reach.value = reach
    }

    /**
     * Another Mac's turn: clears what the last one said and brings back the new
     * one's tabs, which Ready re-attaches as after any reconnect. [clientMacID]
     * becomes [macID] here, so nothing is remembered under the Mac being left.
     */
    private fun switchSessions(macID: String) {
        // Kept so a finished tab can still be removed after switching back while that Mac is out of reach.
        clientMacID?.let { endedByMac[it] = _ended.value }
        resetSessions()
        _ended.value = endedByMac[macID] ?: ShellEndedSessions()
        clientMacID = macID
        val tabs = _tabMemory.value.tabs(macID)
        holdingTabMemory = true
        try {
            shownTabs = tabs.openTabs
            shownActive = tabs.active
        } finally {
            holdingTabMemory = false
        }
    }

    /** Keeps the tabs showing as the connected Mac's. */
    private fun rememberTabs() {
        if (holdingTabMemory) return
        val mac = clientMacID ?: return
        val tabs = MacTabs(_openTabs.value, _activeSession.value)
        if (_tabMemory.value.tabs(mac) == tabs) return
        _tabMemory.value = _tabMemory.value.save(tabs, mac)
        saveTabMemory()
    }

    private fun saveTabMemory() {
        val memory = _tabMemory.value
        Runtime.settings.setShellTabMemory(if (memory.byMac.isEmpty()) null else memory.toJson())
    }

    private fun saveHiddenSessions() {
        Runtime.settings.setShellHiddenSessions(if (hiddenSessions.byMac.isEmpty()) null else hiddenSessions.toJson())
    }

    private fun publishVisible() {
        val mac = clientMacID ?: _selectedMacID.value
        _visibleSessions.value = if (mac == null) _sessions.value else hiddenSessions.visible(_sessions.value, mac)
    }

    /** Drops tab memory and the last-used Mac for Macs no longer paired. */
    private fun forgetUnpaired(paired: Set<String>) {
        endedByMac.keys.retainAll(paired)
        val kept = _tabMemory.value.keepOnly(paired)
        if (kept != _tabMemory.value) {
            _tabMemory.value = kept
            saveTabMemory()
        }
        val keptHidden = hiddenSessions.keepOnly(paired)
        if (keptHidden != hiddenSessions) {
            hiddenSessions = keptHidden
            saveHiddenSessions()
            publishVisible()
        }
        if (Runtime.settings.shellLastMac()?.let { it !in paired } == true) Runtime.settings.setShellLastMac(null)
        val heard = Runtime.settings.shellLastHeard()
        if (heard.keys.any { it !in paired }) Runtime.settings.setShellLastHeard(heard.filterKeys { it in paired })
        val selectedAt = Runtime.settings.shellLastSelectedAt()
        if (selectedAt.keys.any { it !in paired }) Runtime.settings.setShellLastSelectedAt(selectedAt.filterKeys { it in paired })
    }

    /** Clears everything the connected Mac said, tabs included (its tabs stay in [tabMemory]). */
    private fun resetSessions() {
        holdingTabMemory = true
        try {
            resetSessionState()
        } finally {
            holdingTabMemory = false
        }
    }

    private fun resetSessionState() {
        openWhenReady = false
        _macState.value = null
        controls.reset()
        publishControls()
        _timeline.value = null
        _timelineUnsupported.value = false
        timelineLoading = false
        _sessions.value = emptyList()
        _visibleSessions.value = emptyList()
        _history.value = emptyList()
        shownTabs = emptyList()
        shownActive = null
        _detachedSession.value = null
        _ended.value = ShellEndedSessions()
    }

    /**
     * No usable Mac right now: forget keys held in memory and hang up. While
     * merely locked (or without a passcode) the selection and tabs stay, so the
     * next unlock reconnects and re-attaches.
     */
    private fun clear(reach: ShellReach, paired: List<String> = emptyList()) {
        stopRedialing()
        dropConnection()
        watcher.stop()
        keys = emptyMap()
        keyFacts = ShellKeyFacts()
        _macs.value = emptyList()
        if (reach == ShellReach.NO_ACCESS || reach == ShellReach.UNSUPPORTED) {
            discovery.stop()
            // A paired Mac (internet only, or no grant yet) stays selected; with none paired, nothing is.
            _selectedMacID.value = MacProfiles.selection(_selectedMacID.value, Runtime.settings.shellLastMac(), paired, emptyList())
            clientMacID = null
            resetSessions()
        }
        _reach.value = reach
    }

    /** Through the same Mac change as [connect] (tabs kept per Mac), without dialing. */
    private fun seedDemo(state: String) {
        val reach = ShellDemo.reach(state)
        _macs.value = if (reach == ShellReach.NO_ACCESS) emptyList() else ShellDemo.macs
        if (_macs.value.none { it.macID == _selectedMacID.value }) {
            _selectedMacID.value = MacProfiles.reopen(Runtime.settings.shellLastMac(), _macs.value.map { it.macID })
        }
        applyDemoWatch()
        if (reach != ShellReach.READY) {
            _reach.value = reach
            return
        }
        val mac = _selectedMacID.value ?: return
        if (clientMacID != mac) switchSessions(mac)
        handle(ShellEvent.Ready(ShellDemo.path))
        handle(ShellEvent.Sessions(ShellDemo.sessions(mac, _openTabs.value.filter { it.startsWith(ShellDemo.newPrefix(mac)) })))
        handle(ShellEvent.History(ShellDemo.history()))
        if (_macState.value == null) handle(ShellEvent.MacStateChanged(ShellDemo.macState))
    }

    private fun demoAttach(id: String) {
        listeners.toList().forEach { it.streamStarting(id, true) }
        handle(ShellEvent.Output(id, ShellDemo.output(id)))
        handle(ShellEvent.Attached(id))
        ShellDemo.ended(id)?.let(::handle)
    }

    /** The other demo Macs as a watch would see them (the second one's `codex` session is asking), without dialling. */
    private fun applyDemoWatch() {
        val state = demo ?: return
        if (!BuildConfig.DEBUG || ShellDemo.reach(state) != ShellReach.READY) return watcher.demoShow(emptyMap())
        val now = System.currentTimeMillis()
        val ids = MacProfiles.watched(_macs.value.map { it.macID }, _selectedMacID.value, emptyMap(), emptySet(), MacWatcher.LIMIT)
        watcher.demoShow(ids.associateWith { id ->
            val opened = _tabMemory.value.tabs(id).openTabs.filter { it.startsWith(ShellDemo.newPrefix(id)) }
            MacWatcher.Seen(hiddenSessions.visible(ShellDemo.sessions(id, opened), id), ShellDemo.watchedMacState,
                reachable = true, lastHeardMillis = now)
        })
    }

    override fun onCleared() {
        dropConnection()
        watcher.stop()
        discovery.stop()
    }

    companion object {
        /**
         * The wait before each redial after a drop: the first at once
         * (another path, iroh say, usually answers), then backing off.
         * Mirrors ShellModel.redialDelays on iOS.
         */
        val REDIAL_DELAYS_MS = longArrayOf(0, 1_000, 2_000, 4_000, 8_000, 15_000)
    }
}
