package dev.dpatel.passthrough.ui.shell

import dev.dpatel.passthrough.core.IrohInfo
import dev.dpatel.passthrough.core.IrohShellDialer
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.ShellClient
import dev.dpatel.passthrough.core.ShellConnectError
import dev.dpatel.passthrough.core.ShellConnectMode
import dev.dpatel.passthrough.core.ShellConnection
import dev.dpatel.passthrough.core.ShellCredential
import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.ShellEvent
import dev.dpatel.passthrough.core.ShellLiveness
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.service.Runtime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Keeps an eye on the paired Macs other than the selected one while the app
 * is in the foreground: one [ShellConnection] per watched Mac, dialled as
 * [ShellViewModel.connect] dials, that only listens to what the Mac sends
 * unasked (`sessions`, `macState`). It never opens, attaches, closes,
 * resizes, types or changes anything, so the Mac being watched sees no
 * difference. Mirrors iOS/App/Shell/MacWatcher.swift. Main-thread only.
 */
class MacWatcher(
    private val scope: CoroutineScope,
    /** The finished sessions this phone removed, per Mac. */
    private val hiddenSessions: () -> ShellHiddenSessions,
    /** The Bonjour result to dial for a Mac, if any. */
    private val discovered: (ShellCredential) -> Pair<String, Int>?,
    /** How recently each Mac was used (see [MacProfiles.recency]). */
    private val recency: () -> Map<String, Double>,
    /** When a Mac last answered (Unix millis), as stored. */
    private val storedLastHeard: (String) -> Long?,
    /** Stores that a Mac answered (or stopped answering) at a time (Unix millis). */
    private val noteHeard: (String, Long) -> Unit,
) {
    /** What a watched Mac last said. */
    data class Seen(
        /** Its sessions, minus the finished ones this phone removed; null until it sends them. */
        val sessions: List<ShellSessionInfo>?,
        val state: MacState?,
        val reachable: Boolean,
        /** Unix millis. */
        val lastHeardMillis: Long?,
    )

    private val _seen = MutableStateFlow<Map<String, Seen>>(emptyMap())
    /** By Mac ID; only Macs being watched. */
    val seen: StateFlow<Map<String, Seen>> = _seen.asStateFlow()

    private class Watch(val credential: ShellCredential) {
        /** Bumped per dial, so a replaced attempt's late events are dropped. */
        var generation = 0
        /** Dialling, then collecting the connection's events. */
        var job: Job? = null
        var connection: ShellConnection? = null
        var redial: Job? = null
        /** The Mac refused the key: dialling again won't help. */
        var refused = false
    }

    private val watches = HashMap<String, Watch>()
    private var connectMode: ShellConnectMode? = null
    private var generation = 0

    /**
     * Watches the Macs [MacProfiles.watched] picks from [credentials] (never
     * [selected]; every [pinned] one), ending watches no longer wanted. The
     * selected Mac's watch, if it had one, is ended here, before this returns.
     */
    fun update(credentials: List<ShellCredential>, selected: String?, pinned: Set<String>, connectMode: ShellConnectMode) {
        if (this.connectMode != connectMode) {
            stop()
            this.connectMode = connectMode
        }
        val ids = MacProfiles.watched(credentials.map { it.macID }, selected, recency(), pinned, LIMIT)
        val wanted = ids.mapNotNull { id -> credentials.firstOrNull { it.macID == id } }
        val changes = MacProfiles.watchChanges(watches.mapValues { it.value.credential }, wanted)
        changes.stop.forEach(::end)
        for (credential in changes.start) {
            watches[credential.macID] = Watch(credential)
            dial(credential.macID)
        }
    }

    /** Ends every watch (backgrounding, relock) and forgets what they said. */
    fun stop() {
        watches.keys.toList().forEach(::end)
        _seen.value = emptyMap()
    }

    /** Debug builds only, for the demo ([ShellDemo]): what the watched demo Macs say, without dialling. */
    fun demoShow(seen: Map<String, Seen>) {
        watches.keys.toList().forEach(::end)
        _seen.value = seen
    }

    // Private

    private fun end(id: String) {
        val watch = watches.remove(id) ?: return
        watch.redial?.cancel()
        watch.job?.cancel()
        watch.connection?.let(::closeQuietly)
        watch.connection = null
        _seen.value -= id
    }

    private fun dial(id: String) {
        val watch = watches[id] ?: return
        val mode = connectMode ?: return
        watch.redial?.cancel()
        watch.redial = null
        val gen = ++generation
        watch.generation = gen
        val credential = watch.credential
        val wantsIroh = mode == ShellConnectMode.AUTOMATIC && credential.irohID?.let(IrohInfo::isValidID) == true
        val discovered = discovered(credential)
        if (id !in _seen.value) _seen.value += id to Seen(null, null, reachable = false, lastHeardMillis = storedLastHeard(id))
        watch.job = scope.launch {
            // Set once dialled: a cancel that lands as the dial returns must still hang it up.
            var made: ShellConnection? = null
            val conn = try {
                withContext(Dispatchers.IO) {
                    // A fresh iroh endpoint per connect, as for the live connection.
                    val iroh = if (wantsIroh && Runtime.iroh.ensure()) IrohShellDialer() else null
                    ShellClient.connect(credential, discovered, scope, iroh, mode, LIVENESS).also { made = it }
                }
            } catch (e: CancellationException) {
                made?.let(::closeQuietly)
                throw e
            } catch (e: ShellConnectError.Refused) {
                if (current(id, gen)) {
                    if (e.reason == ShellError.NOT_AUTHORIZED) watch.refused = true else scheduleRedial(id)
                }
                return@launch
            } catch (_: Exception) {
                if (current(id, gen)) scheduleRedial(id)
                return@launch
            }
            if (!current(id, gen)) {
                closeQuietly(conn)
                return@launch
            }
            watch.connection = conn
            conn.events.transformWhile { emit(it); it !is ShellEvent.Disconnected }.collect { event ->
                if (current(id, gen)) handle(event, id, watch)
            }
        }
    }

    private fun current(id: String, gen: Int): Boolean = watches[id]?.generation == gen

    private fun handle(event: ShellEvent, id: String, watch: Watch) {
        when (event) {
            is ShellEvent.Ready -> {
                val now = System.currentTimeMillis()
                noteHeard(id, now)
                updateSeen(id) { it.copy(reachable = true, lastHeardMillis = now) }
            }
            is ShellEvent.Sessions -> updateSeen(id) { it.copy(sessions = hiddenSessions().visible(event.sessions, id)) }
            is ShellEvent.MacStateChanged -> updateSeen(id) { it.copy(state = event.state) }
            is ShellEvent.Failed -> if (event.error == ShellError.NOT_AUTHORIZED) watch.refused = true
            is ShellEvent.Disconnected -> {
                watch.connection = null
                if (_seen.value[id]?.reachable == true) {
                    val now = System.currentTimeMillis()
                    noteHeard(id, now)
                    updateSeen(id) { it.copy(reachable = false, lastHeardMillis = now) }
                }
                // null: this side hung up.
                if (event.error != null && !watch.refused) scheduleRedial(id)
            }
            // Nothing a watch asks for (`Ended` is followed by a fresh `sessions`).
            is ShellEvent.MacInfo, is ShellEvent.Events, is ShellEvent.Opened, is ShellEvent.OpenedDetached,
            is ShellEvent.Output, is ShellEvent.Attached, is ShellEvent.Ended, is ShellEvent.Detached,
            is ShellEvent.History, is ShellEvent.Transcript -> Unit
        }
    }

    private fun updateSeen(id: String, change: (Seen) -> Seen) {
        val seen = _seen.value[id] ?: return
        _seen.value += id to change(seen)
    }

    /** Dials again after [REDIAL_DELAY_MS]; [stop] (backgrounding, relock) cancels it. */
    private fun scheduleRedial(id: String) {
        val watch = watches[id] ?: return
        watch.redial?.cancel()
        watch.redial = scope.launch {
            delay(REDIAL_DELAY_MS)
            if (watches[id] !== watch || watch.connection != null) return@launch
            watch.redial = null
            dial(id)
        }
    }

    /** close() does the TLS close_notify, which may block: never on the main thread. */
    private fun closeQuietly(conn: ShellConnection) {
        scope.launch(Dispatchers.IO) { conn.close() }
    }

    companion object {
        /** The wait before dialling a watched Mac again after it dropped or couldn't be reached. */
        const val REDIAL_DELAY_MS = 30_000L
        /** At most this many Macs besides pinned ones. */
        const val LIMIT = 4
        /**
         * Slower than the live connection's: a watch only needs to notice a
         * dead connection eventually, and each ping costs battery and data.
         */
        val LIVENESS = ShellLiveness(intervalMs = 15_000, silenceMs = 45_000)
    }
}
