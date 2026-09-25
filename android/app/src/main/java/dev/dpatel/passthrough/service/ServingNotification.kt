package dev.dpatel.passthrough.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import dev.dpatel.passthrough.MainActivity
import dev.dpatel.passthrough.R
import dev.dpatel.passthrough.core.ByteFormat
import dev.dpatel.passthrough.core.ProviderStats

/** The ongoing notification the foreground service must show: who is online through this phone, and a Stop button. */
internal class ServingNotification(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun build(serving: Boolean, stats: ProviderStats, radio: String?): Notification {
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Passthrough", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while this phone is sharing its connection over USB"
                setShowBadge(false)
            })
        }
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(context, 1, Intent(context, PassthroughService::class.java).setAction(PassthroughService.ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val macs = stats.macs
        val title = when {
            !serving -> "Starting Passthrough"
            macs.isEmpty() -> "Waiting for a Mac on USB"
            macs.size == 1 -> "${macs.first().name} is online through this phone"
            else -> "Serving ${macs.size} Macs over USB"
        }
        val text = if (macs.isEmpty()) "Connect from Passthrough in the Mac's menu bar." else {
            val month = Runtime.usage.usage.value.monthTotal
            "${radio ?: "Cellular"} · ${stats.active} open · ${ByteFormat.bytes(stats.rx + stats.tx)} this session · ${ByteFormat.bytes(month)} this month"
        }
        return NotificationCompat.Builder(context, CHANNEL_ID)
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

    fun update(stats: ProviderStats, radio: String?) {
        runCatching { manager.notify(ID, build(serving = true, stats, radio)) }
    }

    companion object {
        const val ID = 1
        private const val CHANNEL_ID = "passthrough"
    }
}
