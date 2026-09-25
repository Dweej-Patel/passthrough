package dev.dpatel.passthrough.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.dpatel.passthrough.core.ByteCounter
import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.TrafficMeter
import dev.dpatel.passthrough.service.PassthroughService
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.service.ServiceState
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Everything the screens observe. The service does the work; this only watches it. */
class AppViewModel(app: Application) : AndroidViewModel(app) {
    val state = Runtime.state
    val stats = Runtime.stats
    val pairedClients = Runtime.pairedClients
    val pairingCode = Runtime.pairingCode
    val usage = Runtime.usage.usage
    val settings = Runtime.settings

    private val _meter = MutableStateFlow(TrafficMeter())
    val meter: StateFlow<TrafficMeter> = _meter
    private val _radio = MutableStateFlow<String?>(null)
    val radio: StateFlow<String?> = _radio
    private val _usbDebugging = MutableStateFlow(true)
    val usbDebugging: StateFlow<Boolean> = _usbDebugging
    private val _now = MutableStateFlow(System.currentTimeMillis())
    val now: StateFlow<Long> = _now
    private val _log = MutableStateFlow(PtLog.snapshot())
    val log: StateFlow<List<PtLog.Entry>> = _log

    init {
        PtLog.onAppend = { e -> _log.update { (it + e).takeLast(400) } }
        viewModelScope.launch {
            while (true) {
                refresh()
                delay(1000)
            }
        }
        viewModelScope.launch {
            Runtime.stats.collect { s ->
                val fresh = (_meter.value.lastDate ?: 0L) < s.sampledAt
                if (Runtime.state.value == ServiceState.Running && fresh) {
                    _meter.update { it.record(ByteCounter.Snapshot(s.rx, s.tx, s.active, s.totalConnections), s.sampledAt) }
                }
            }
        }
    }

    private fun refresh() {
        _now.value = System.currentTimeMillis()
        val running = state.value == ServiceState.Running
        _radio.value = Runtime.facts.radio(settings.cellularOnly.value, running, Runtime.cellularFallback.value)
        _usbDebugging.value = Runtime.facts.usbDebuggingEnabled()
        Runtime.usage.rolloverIfNeeded()
        if (pairingCode.value != null && Runtime.registry.activeCode == null) Runtime.refreshPairing()
        if (!running && (_meter.value.downRate != 0.0 || _meter.value.upRate != 0.0)) _meter.value = TrafficMeter()
    }

    fun toggle() = if (state.value.isActive) stop() else start()

    fun start() {
        if (state.value.isActive) return
        _meter.value = TrafficMeter()
        Runtime.setState(ServiceState.Starting)
        PassthroughService.start(getApplication())
    }

    fun stop() {
        if (!state.value.isActive) return
        PassthroughService.stop(getApplication())
    }

    fun beginPairing() { Runtime.registry.issueCode() }
    fun endPairing() { Runtime.registry.clearCode() }
    fun revoke(client: PairedClient) = Runtime.registry.revoke(client.id)
    fun revokeAll() = Runtime.registry.revokeAll()
    fun resetMonth() = Runtime.usage.resetMonth()
    fun clearLog() { PtLog.clear(); _log.value = emptyList() }
    fun phonePermissionGranted() = Runtime.facts.registerDisplayInfo()

    override fun onCleared() {
        PtLog.onAppend = null
    }
}
