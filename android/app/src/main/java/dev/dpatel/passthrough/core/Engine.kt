package dev.dpatel.passthrough.core

/**
 * Bundles the SOCKS5 server and the control channel behind one switch.
 * The Android counterpart of PassthroughCore/PassthroughService.swift.
 */
class PassthroughEngine(
    val registry: PairingRegistry,
    val options: Options = Options(),
    private val egress: EgressProvider = DefaultEgress,
    private val statusProvider: () -> DeviceStatus,
) {
    data class Options(
        val socksPort: Int = PassthroughProtocol.DEFAULT_SOCKS_PORT,
        val controlPort: Int = PassthroughProtocol.DEFAULT_CONTROL_PORT,
        val allowUDP: Boolean = true,
        val disableAuth: Boolean = false,
        /** Dev servers legitimately talk to loopback/LAN targets. */
        val refuseLocalDestinations: Boolean = true,
    )

    var socks: Socks5Server? = null
        private set
    var control: ControlServer? = null
        private set
    private val fallbackCounter = ByteCounter()
    val counter: ByteCounter get() = socks?.counter ?: fallbackCounter
    @Volatile var onClientsChanged: ((List<ConnectedMac>) -> Unit)? = null
    var startedAt: Long? = null
        private set

    val isRunning: Boolean get() = socks?.isRunning ?: false

    @Synchronized
    fun start() {
        if (isRunning) return
        val registry = registry
        val auth: ((String, String) -> Boolean)? = if (options.disableAuth) null else { user, pass -> registry.verify(user, pass) }
        val socks = Socks5Server(
            Socks5Server.Config(port = options.socksPort, allowUDP = options.allowUDP, refuseLocalDestinations = options.refuseLocalDestinations),
            auth, egress,
        )
        // The Mac blocks IPv6 in its tunnel when the phone's network has none,
        // so apps fall back to IPv4 at once instead of hanging.
        val control = ControlServer(options.controlPort, options.socksPort, registry, socks.counter) {
            statusProvider().copy(ipv6 = egress.acquire(0)?.hasIPv6())
        }
        control.onClientsChanged = { onClientsChanged?.invoke(it) }
        socks.start()
        try { control.start() } catch (e: Exception) { socks.stop(); throw e }
        this.socks = socks
        this.control = control
        startedAt = System.currentTimeMillis()
    }

    @Synchronized
    fun stop() {
        control?.stop()
        socks?.stop()
        control = null
        socks = null
        startedAt = null
    }

    val connectedMacs: List<ConnectedMac> get() = control?.connectedMacs ?: emptyList()

    /** Current counters, connected Macs and start time, in the shape the app shows. */
    fun stats(): ProviderStats {
        val snap = counter.snapshot()
        return ProviderStats(snap.rx, snap.tx, snap.active, snap.totalConnections, connectedMacs, startedAt)
    }
}

/** What the service publishes once a second. Same shape as the Swift ProviderStats. */
data class ProviderStats(
    val rx: Long = 0,
    val tx: Long = 0,
    val active: Int = 0,
    val totalConnections: Int = 0,
    val macs: List<ConnectedMac> = emptyList(),
    val startedAt: Long? = null,
    /** When this snapshot was taken; makes every tick a distinct value so idle seconds still reach the meter. */
    val sampledAt: Long = System.currentTimeMillis(),
)
