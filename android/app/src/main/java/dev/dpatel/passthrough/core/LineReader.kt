package dev.dpatel.passthrough.core

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

/**
 * Reads newline-terminated lines, the control channel's framing. Mirrors
 * LineBuffer in PassthroughCore/ControlConnection.swift, including the cap
 * that stops a peer from ballooning memory with an endless line.
 */
class LineReader(input: InputStream, private val limit: Int = DEFAULT_LIMIT) {
    private val input = input as? BufferedInputStream ?: BufferedInputStream(input)

    /** The next non-empty line, or null at end of stream. Throws when a line exceeds the limit. */
    fun next(): String? {
        val line = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) {
                if (line.size() == 0) continue
                return line.toString(Charsets.UTF_8.name())
            }
            line.write(b)
            if (line.size() > limit) throw IOException("control line too long")
        }
    }

    companion object { const val DEFAULT_LIMIT = 256 * 1024 }
}
