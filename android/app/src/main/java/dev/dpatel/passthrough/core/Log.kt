package dev.dpatel.passthrough.core

import java.io.File
import java.util.concurrent.Executors

/**
 * Small ring log surfaced in the diagnostics view, mirrored to logcat (via
 * [platformSink]) and optionally to a file so it survives the UI going away.
 */
object PtLog {
    enum class Level { DEBUG, INFO, WARNING, ERROR }

    data class Entry(val date: Long, val level: Level, val message: String) {
        val id: Long get() = (date * 31 + message.hashCode()) * 7 + level.ordinal
    }

    private const val CAPACITY = 400
    private val lock = Any()
    private val entries = ArrayDeque<Entry>()
    private var file: File? = null
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "pt-log").apply { isDaemon = true } }

    /** Forwarded every entry (e.g. to android.util.Log). */
    @Volatile var platformSink: ((Level, String) -> Unit)? = null
    @Volatile var onAppend: ((Entry) -> Unit)? = null

    fun attachFile(f: File) {
        synchronized(lock) {
            file = f
            if (entries.isEmpty()) entries.addAll(loadPersisted(f))
        }
    }

    fun log(level: Level, message: String) {
        val entry = Entry(System.currentTimeMillis(), level, message)
        val target: File?
        synchronized(lock) {
            entries.addLast(entry)
            while (entries.size > CAPACITY) entries.removeFirst()
            target = file
        }
        platformSink?.invoke(level, message)
        onAppend?.invoke(entry)
        if (target != null) io.execute {
            runCatching {
                target.appendText("${entry.date}\t${entry.level.name}\t${message.replace('\n', ' ')}\n")
                if (target.length() > 512 * 1024) {
                    val keep = target.readLines().takeLast(CAPACITY)
                    target.writeText(keep.joinToString("\n", postfix = "\n"))
                }
            }
        }
    }

    fun snapshot(): List<Entry> = synchronized(lock) { entries.toList() }

    fun clear() {
        val target = synchronized(lock) { entries.clear(); file }
        if (target != null) io.execute { runCatching { target.writeText("") } }
    }

    private fun loadPersisted(f: File): List<Entry> = runCatching {
        f.readLines().takeLast(CAPACITY).mapNotNull { line ->
            val parts = line.split('\t', limit = 3)
            if (parts.size != 3) return@mapNotNull null
            val date = parts[0].toLongOrNull() ?: return@mapNotNull null
            val level = runCatching { Level.valueOf(parts[1]) }.getOrNull() ?: return@mapNotNull null
            Entry(date, level, parts[2])
        }
    }.getOrDefault(emptyList())
}

fun ptLog(level: PtLog.Level, message: String) = PtLog.log(level, message)
