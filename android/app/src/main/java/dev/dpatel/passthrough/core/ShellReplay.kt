package dev.dpatel.passthrough.core

import java.io.ByteArrayOutputStream

/**
 * One step of a recorded session's replay: output, or the terminal taking a
 * new size. A replay from a Mac that records sizes starts with one, so it is
 * fed at the width the shell drew for (zsh relies on autowrap at the right
 * margin: fed at another width, a line that reached the margin is erased).
 * Mirrors ShellReplayChunk in PassthroughCore/ShellReplay.swift.
 */
sealed interface ShellReplayChunk {
    class Output(val data: ByteArray) : ShellReplayChunk {
        override fun equals(other: Any?) = other is Output && data.contentEquals(other.data)
        override fun hashCode() = data.contentHashCode()
        override fun toString() = "Output(${data.size} bytes)"
    }

    data class Resize(val cols: Int, val rows: Int) : ShellReplayChunk
}

/** Receiving and showing replays (protocol/README.md, `transcriptData`). Mirrors ShellReplay in ShellReplay.swift. */
object ShellReplay {
    /** A size outside 1..this in either direction is not one a terminal had: ignored. */
    const val MAX_DIMENSION = 1000

    fun isValid(cols: Int, rows: Int): Boolean = cols in 1..MAX_DIMENSION && rows in 1..MAX_DIMENSION

    /** The most columns and the most rows the replay's sizes ask for; null when it has none. */
    fun largestGrid(chunks: List<ShellReplayChunk>): Pair<Int, Int>? {
        var cols = 0
        var rows = 0
        for (c in chunks) if (c is ShellReplayChunk.Resize) {
            cols = maxOf(cols, c.cols)
            rows = maxOf(rows, c.rows)
        }
        return if (cols > 0 && rows > 0) cols to rows else null
    }

    /** How much a font must shrink (never grow) for [needed] to fit [available], but not below [minimum]. */
    fun fitScale(neededWidth: Float, neededHeight: Float, availableWidth: Float, availableHeight: Float, minimum: Float): Float {
        if (neededWidth <= 0 || neededHeight <= 0 || availableWidth <= 0 || availableHeight <= 0) return 1f
        val scale = minOf(1f, availableWidth / neededWidth, availableHeight / neededHeight)
        return maxOf(minOf(minimum, 1f), scale)
    }

    /** A replay rebuilt from `transcriptData` lines, in order. */
    class Collector {
        private val done = ArrayList<ShellReplayChunk>()
        private val pending = ByteArrayOutputStream()

        /** One line's contents: its size change (if any, and valid) comes before its data. */
        fun add(data: ByteArray, cols: Int? = null, rows: Int? = null) {
            if (cols != null && rows != null && isValid(cols, rows)) {
                flush()
                done += ShellReplayChunk.Resize(cols, rows)
            }
            pending.write(data)
        }

        /** The replay so far: consecutive output joined. */
        fun chunks(): List<ShellReplayChunk> {
            flush()
            return done.toList()
        }

        private fun flush() {
            if (pending.size() == 0) return
            done += ShellReplayChunk.Output(pending.toByteArray())
            pending.reset()
        }
    }
}
