package dev.dpatel.passthrough.service

import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.core.PairingRegistry
import dev.dpatel.passthrough.core.ProviderStats
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

sealed interface ServiceState {
    data object Stopped : ServiceState
    data object Starting : ServiceState
    data object Running : ServiceState
    data object Stopping : ServiceState
    data class Failed(val message: String) : ServiceState

    val isActive: Boolean get() = this == Starting || this == Running
}

/**
 * Process-wide state shared by the foreground service and the UI (same
 * process, so plain singletons and flows are enough). The service publishes,
 * the UI observes. Initialised in [dev.dpatel.passthrough.PassthroughApp].
 */
object Runtime {
    lateinit var settings: AppSettings
    lateinit var registry: PairingRegistry
    lateinit var usage: UsageLedger
    @android.annotation.SuppressLint("StaticFieldLeak") // holds the application context only
    lateinit var facts: DeviceFacts

    private val _state = MutableStateFlow<ServiceState>(ServiceState.Stopped)
    val state: StateFlow<ServiceState> = _state
    private val _stats = MutableStateFlow(ProviderStats())
    val stats: StateFlow<ProviderStats> = _stats
    private val _pairedClients = MutableStateFlow<List<PairedClient>>(emptyList())
    val pairedClients: StateFlow<List<PairedClient>> = _pairedClients
    private val _pairingCode = MutableStateFlow<PairingRegistry.Code?>(null)
    val pairingCode: StateFlow<PairingRegistry.Code?> = _pairingCode
    private val _cellularFallback = MutableStateFlow(false)
    /** True while "cellular only" is temporarily using another network. */
    val cellularFallback: StateFlow<Boolean> = _cellularFallback

    fun setState(state: ServiceState) { _state.value = state }
    fun updateStats(transform: (ProviderStats) -> ProviderStats) = _stats.update(transform)
    fun setCellularFallback(active: Boolean) { _cellularFallback.value = active }

    /** Re-reads paired Macs and the code on screen (gone once used or expired). */
    fun refreshPairing() {
        _pairedClients.value = registry.clients
        _pairingCode.value = registry.activeCode
    }
}
