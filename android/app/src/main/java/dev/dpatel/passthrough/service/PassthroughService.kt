package dev.dpatel.passthrough.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.dpatel.passthrough.MainActivity
import dev.dpatel.passthrough.R
import dev.dpatel.passthrough.core.ByteFormat
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
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type)
    }

    private fun startEngine() {
        Runtime.state.value = ServiceState.Starting
        val settings = Runtime.settings
        val cellularOnly = settings.cellularOnly.value
        Runtime.cellularFallback.value = false
        val egress = if (cellularOnly) {
            CellularEgressProvider(this, onUsableChange = { usable -> Runtime.cellularFallback.value = !usable }).also { it.start(); cellular = it }
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
            Runtime.stats.value = Runtime.stats.value.copy(macs = macs)
            // A Mac just paired: the code on screen has done its job.
            if (macs.isNotEmpty()) Runtime.pairingCode.value = Runtime.registry.activeCode
            handler.post { updateNotification() }
        }
        try {
            engine.start()
        } catch (e: Exception) {
            val message = if (e is BindException) "Port ${options.socksPort} or ${options.controlPort} is already in use on this phone." else (e.message ?: e.toString())
            ptLog(PtLog.Level.ERROR, "Could not start: $message")
            cellular?.stop(); cellular = null
            Runtime.state.value = ServiceState.Failed(message)
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        this.engine = engine
        // Keep the CPU serving with the screen off; the phone is on USB power anyway.
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Passthrough::serving").apply { setReferenceCounted(false); acquire(WAKE_LOCK_MS) }
        lastUsage = null
        Runtime.stats.value = ProviderStats(startedAt = engine.startedAt)
        Runtime.state.value = ServiceState.Running
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
        val snap = engine.counter.snapshot()
        Runtime.stats.value = ProviderStats(snap.rx, snap.tx, snap.active, snap.totalConnections, engine.connectedMacs, engine.startedAt)
        lastUsage?.let { (rx, tx) -> Runtime.usage.add(maxOf(0, snap.rx - rx), maxOf(0, snap.tx - tx)) }
        lastUsage = snap.rx to snap.tx
        if (Runtime.pairingCode.value != null && Runtime.registry.activeCode == null) Runtime.pairingCode.value = null
        if (ticks % 2 == 0) updateNotification()
        if (ticks % 60 == 0) wakeLock?.acquire(WAKE_LOCK_MS)
    }

    private fun shutdown() {
        handler.removeCallbacks(ticker)
        if (engine != null || Runtime.state.value.isActive) Runtime.state.value = ServiceState.Stopping
        engine?.stop()
        engine = null
        cellular?.stop(); cellular = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        Runtime.stats.value = Runtime.stats.value.copy(active = 0, macs = emptyList(), startedAt = null)
        if (Runtime.state.value !is ServiceState.Failed) Runtime.state.value = ServiceState.Stopped
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    // Notification

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Passthrough", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while this phone is sharing its connection over USB"
                setShowBadge(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, PassthroughService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stats = Runtime.stats.value
        val macs = stats.macs
        val title = when {
            engine == null -> "Starting Passthrough"
            macs.isEmpty() -> "Waiting for a Mac on USB"
            macs.size == 1 -> "${macs.first().name} is online through this phone"
            else -> "Serving ${macs.size} Macs over USB"
        }
        val text = if (macs.isEmpty()) "Connect from Passthrough in the Mac's menu bar." else {
            val u = Runtime.usage.usage.value
            "${radio ?: "Cellular"} · ${stats.active} open · ${ByteFormat.bytes(stats.rx + stats.tx)} this session · ${ByteFormat.bytes(u.monthTotal)} this month"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_passthrough)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }

    private fun updateNotification() {
        if (engine == null) return
        runCatching { getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification()) }
    }

    companion object {
        private const val CHANNEL_ID = "passthrough"
        private const val NOTIFICATION_ID = 1
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
