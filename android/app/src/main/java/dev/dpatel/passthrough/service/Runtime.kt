package dev.dpatel.passthrough.service

import dev.dpatel.passthrough.core.ConnectedMac
import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.core.PairingRegistry
import kotlinx.coroutines.flow.MutableStateFlow

sealed interface ServiceState {
    data object Stopped : ServiceState
    data object Starting : ServiceState
    data object Running : ServiceState
    data object Stopping : ServiceState
    data class Failed(val message: String) : ServiceState

    val isActive: Boolean get() = this == Starting || this == Running
}

/** Snapshot the service publishes once a second. Same shape as iOS ProviderStats. */
data class ProviderStats(
    val rx: Long = 0,
    val tx: Long = 0,
    val active: Int = 0,
    val totalConnections: Int = 0,
    val macs: List<ConnectedMac> = emptyList(),
    val startedAt: Long? = null,
    /** When the service took this snapshot; makes every tick a distinct value so idle seconds still reach the meter. */
    val sampledAt: Long = System.currentTimeMillis(),
)

/**
 * Process-wide state shared by the foreground service and the UI (same
 * process, so plain singletons and flows are enough). Initialised in
 * [dev.dpatel.passthrough.PassthroughApp].
 */
object Runtime {
    lateinit var settings: AppSettings
    lateinit var registry: PairingRegistry
    lateinit var usage: UsageLedger
    @android.annotation.SuppressLint("StaticFieldLeak") // holds the application context only
    lateinit var facts: DeviceFacts

    val state = MutableStateFlow<ServiceState>(ServiceState.Stopped)
    val stats = MutableStateFlow(ProviderStats())
    val pairedClients = MutableStateFlow<List<PairedClient>>(emptyList())
    val pairingCode = MutableStateFlow<PairingRegistry.Code?>(null)
    /** True while "cellular only" is temporarily using another network. */
    val cellularFallback = MutableStateFlow(false)

    fun refreshPairing() {
        pairedClients.value = registry.clients
        pairingCode.value = registry.activeCode
    }
}
