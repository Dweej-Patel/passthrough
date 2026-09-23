package dev.dpatel.passthrough.core

import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** Byte counters updated from network threads and read from the UI. */
class ByteCounter {
    private val rx = AtomicLong()
    private val tx = AtomicLong()
    private val active = AtomicInteger()
    private val total = AtomicInteger()

    fun addRx(n: Int) { rx.addAndGet(n.toLong()) }
    fun addTx(n: Int) { tx.addAndGet(n.toLong()) }
    fun connectionOpened() { active.incrementAndGet(); total.incrementAndGet() }
    fun connectionClosed() { active.updateAndGet { maxOf(0, it - 1) } }

    data class Snapshot(val rx: Long, val tx: Long, val active: Int, val totalConnections: Int) {
        companion object { val ZERO = Snapshot(0, 0, 0, 0) }
    }

    fun snapshot() = Snapshot(rx.get(), tx.get(), active.get(), total.get())
}

/** One second of throughput, used for the chart. */
data class ThroughputSample(val id: Int, val date: Long, val down: Double, val up: Double)

/** Turns raw byte counters into rates and a short history window. */
data class TrafficMeter(
    val history: List<ThroughputSample> = emptyHistory(60),
    val downRate: Double = 0.0,
    val upRate: Double = 0.0,
    val last: ByteCounter.Snapshot = ByteCounter.Snapshot.ZERO,
    val lastDate: Long? = null,
    val windowSize: Int = 60,
    private val counter: Int = 0,
) {
    fun record(snapshot: ByteCounter.Snapshot, date: Long = System.currentTimeMillis()): TrafficMeter {
        val previous = lastDate ?: return copy(last = snapshot, lastDate = date)
        val dt = maxOf(0.05, (date - previous) / 1000.0)
        val down = maxOf(0.0, (snapshot.rx - last.rx) / dt)
        val up = maxOf(0.0, (snapshot.tx - last.tx) / dt)
        val h = (history + ThroughputSample(counter, date, down, up)).takeLast(windowSize)
        return copy(history = h, downRate = down, upRate = up, last = snapshot, lastDate = date, counter = counter + 1)
    }

    val peakRate: Double get() = history.maxOfOrNull { maxOf(it.down, it.up) } ?: 0.0

    companion object {
        fun emptyHistory(n: Int): List<ThroughputSample> {
            val now = System.currentTimeMillis()
            return (0 until n).map { i -> ThroughputSample(i - n, now + (i - n) * 1000L, 0.0, 0.0) }
        }
    }
}

object ByteFormat {
    /** Binary units with the same wording as Apple's ByteCountFormatter (.binary). */
    fun bytes(value: Long): String {
        if (value < 1024) return "$value bytes"
        val units = listOf("KB", "MB", "GB", "TB")
        var v = value / 1024.0
        var i = 0
        while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
        val text = if (v < 10 && i > 0) String.format(Locale.US, "%.2f", v) else if (v < 100) String.format(Locale.US, "%.1f", v) else String.format(Locale.US, "%.0f", v)
        return "$text ${units[i]}"
    }

    /** e.g. "12.4" + "MB/s"; always two significant components for stable layout. */
    fun rate(bytesPerSecond: Double): Pair<String, String> {
        val units = listOf("B/s", "KB/s", "MB/s", "GB/s")
        var v = bytesPerSecond
        var i = 0
        while (v >= 1000 && i < units.size - 1) { v /= 1000; i++ }
        val text = when {
            i == 0 -> String.format(Locale.US, "%.0f", v)
            v < 10 -> String.format(Locale.US, "%.2f", v)
            v < 100 -> String.format(Locale.US, "%.1f", v)
            else -> String.format(Locale.US, "%.0f", v)
        }
        return text to units[i]
    }

    fun duration(seconds: Long): String {
        val s = maxOf(0, seconds)
        return if (s < 3600) String.format(Locale.US, "%02d:%02d", s / 60, s % 60)
        else String.format(Locale.US, "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
