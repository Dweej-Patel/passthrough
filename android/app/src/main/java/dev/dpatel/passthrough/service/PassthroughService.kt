package dev.dpatel.passthrough.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.dpatel.passthrough.core.DefaultEgress
import dev.dpatel.passthrough.core.DeviceStatus
import dev.dpatel.passthrough.core.PassthroughEngine
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ptLog
import java.net.BindException

/**
 * Hosts the SOCKS5 server and control channel. A foreground service keeps it
 * serving with the screen off, the Android counterpart of the iOS packet
 * tunnel extension; it routes none of the phone's own traffic.
 */
class PassthroughService : Service() {
    private var engine: PassthroughEngine? = null
    private var cellular: CellularEgressProvider? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val notification by lazy { ServingNotification(this) }
    private var lastUsage: Pair<Long, Long>? = null
    private var ticks = 0
    @Volatile private var radio: String? = null
    @Volatile private var batteryLevel: Double? = null
    @Volatile private var carrier: String? = null

    private val ticker = object : Runnable {
        override fun run() {
            tick()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                goForeground()
                if (engine == null) startEngine()
            }
        }
        // Not sticky: after a crash the user starts it again, like the iOS app.
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        ServiceCompat.startForeground(this, ServingNotification.ID, notification.build(engine != null, Runtime.stats.value, radio), type)
    }

    private fun startEngine() {
        Runtime.setState(ServiceState.Starting)
        val settings = Runtime.settings
        val cellularOnly = settings.cellularOnly.value
        Runtime.setCellularFallback(false)
        val egress = if (cellularOnly) {
            CellularEgressProvider(this, onUsableChange = { usable -> Runtime.setCellularFallback(!usable) }).also { it.start(); cellular = it }
        } else DefaultEgress
        refreshFacts()
        val options = PassthroughEngine.Options(
            socksPort = settings.socksPort.value,
            controlPort = settings.controlPort.value,
            allowUDP = settings.allowUDP.value,
        )
        val engine = PassthroughEngine(Runtime.registry, options, egress) {
            DeviceStatus(Runtime.settings.deviceName.value, radio, carrier, batteryLevel, hosting = "background")
        }
        engine.onClientsChanged = { macs ->
            Runtime.updateStats { it.copy(macs = macs) }
            // A Mac just paired: the code on screen has done its job.
            if (macs.isNotEmpty()) Runtime.refreshPairing()
            handler.post { updateNotification() }
        }
        try {
            engine.start()
        } catch (e: Exception) {
            val message = if (e is BindException) "Port ${options.socksPort} or ${options.controlPort} is already in use on this phone." else (e.message ?: e.toString())
            ptLog(PtLog.Level.ERROR, "Could not start: $message")
            cellular?.stop(); cellular = null
            Runtime.setState(ServiceState.Failed(message))
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        this.engine = engine
        // Keep the CPU serving with the screen off; the phone is on USB power anyway.
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Passthrough::serving").apply { setReferenceCounted(false); acquire(WAKE_LOCK_MS) }
        lastUsage = null
        Runtime.updateStats { engine.stats() }
        Runtime.setState(ServiceState.Running)
        ptLog(PtLog.Level.INFO, "Serving in the background. Plug in your Mac and connect from its menu bar.")
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    private fun refreshFacts() {
        val facts = Runtime.facts
        val running = engine != null
        radio = facts.radio(Runtime.settings.cellularOnly.value, running, Runtime.cellularFallback.value)
        batteryLevel = facts.battery()
        carrier = facts.carrier()
    }

    private fun tick() {
        val engine = engine ?: return
        ticks++
        refreshFacts()
        val stats = engine.stats()
        Runtime.updateStats { stats }
        lastUsage?.let { (rx, tx) -> Runtime.usage.add(maxOf(0, stats.rx - rx), maxOf(0, stats.tx - tx)) }
        lastUsage = stats.rx to stats.tx
        if (Runtime.pairingCode.value != null && Runtime.registry.activeCode == null) Runtime.refreshPairing()
        if (ticks % 2 == 0) updateNotification()
        if (ticks % 60 == 0) wakeLock?.acquire(WAKE_LOCK_MS)
    }

    private fun shutdown() {
        handler.removeCallbacks(ticker)
        if (engine != null || Runtime.state.value.isActive) Runtime.setState(ServiceState.Stopping)
        engine?.stop()
        engine = null
        cellular?.stop(); cellular = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        Runtime.updateStats { it.copy(active = 0, macs = emptyList(), startedAt = null) }
        if (Runtime.state.value !is ServiceState.Failed) Runtime.setState(ServiceState.Stopped)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    private fun updateNotification() {
        if (engine != null) notification.update(Runtime.stats.value, radio)
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    companion object {
        /** Renewed every minute while serving, so a crash can never leave the CPU held for long. */
        private const val WAKE_LOCK_MS = 10 * 60 * 1000L
        const val ACTION_START = "dev.dpatel.passthrough.START"
        const val ACTION_STOP = "dev.dpatel.passthrough.STOP"

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, PassthroughService::class.java).setAction(ACTION_START))
        }

        fun stop(context: Context) {
            context.startService(Intent(context, PassthroughService::class.java).setAction(ACTION_STOP))
        }
    }
}
