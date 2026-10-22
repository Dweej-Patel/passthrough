package dev.dpatel.passthrough.ui.shell

import com.termux.terminal.TerminalOutput
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellReplay
import dev.dpatel.passthrough.core.ShellReplayChunk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Termux's emulator runs on the JVM, so stream resets can be checked without a device. */
class ShellEmulatorsTests {
    private class Sink : TerminalOutput() {
        val written = StringBuilder()
        override fun write(data: ByteArray, offset: Int, count: Int) { written.append(String(data, offset, count, Charsets.UTF_8)) }
        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit
        override fun onCopyTextToClipboard(text: String?) = Unit
        override fun onPasteTextFromClipboard() = Unit
        override fun onBell() = Unit
        override fun onColorsChanged() = Unit
    }

    private fun feed(e: com.termux.terminal.TerminalEmulator, s: String) = s.toByteArray().let { e.append(it, it.size) }

    @Test fun risAloneLeavesTheAlternateScreenActive() {
        // Why ShellTerminalView.reset() makes a new emulator instead of sending ESC c.
        val e = ShellEmulators.create(Sink(), 80, 24, 10, 20, 1000)
        feed(e, "\u001b[?1049h\u001b[?1h")
        assertTrue(e.isAlternateBufferActive)
        feed(e, "\u001bc")
        assertTrue(e.isAlternateBufferActive)
    }

    @Test fun aFreshEmulatorStartsOnTheMainScreenWithNormalModes() {
        val old = ShellEmulators.create(Sink(), 100, 30, 10, 20, 1000)
        feed(old, "\u001b[?1049h\u001b[?1h\u001b[?1000h")
        val fresh = ShellEmulators.create(Sink(), old.mColumns, old.mRows, 10, 20, 1000)
        assertFalse(fresh.isAlternateBufferActive)
        assertFalse(fresh.isCursorKeysApplicationMode)
        assertFalse(fresh.isMouseTrackingActive)
        assertEquals(100, fresh.mColumns)
        assertEquals(30, fresh.mRows)
        assertEquals(0, fresh.screen.activeTranscriptRows)
    }

    @Test fun repliesGoToTheOutput() {
        val sink = Sink()
        val e = ShellEmulators.create(sink, 80, 24, 10, 20, 1000)
        feed(e, "\u001b[6n")
        assertEquals("\u001b[1;1R", sink.written.toString())
    }

    /**
     * The user's recording, made on a phone at 48 columns: zsh filled the line to
     * the margin and relied on autowrap (" " wraps, "\r\e[K" clears the new line).
     * Fed at the recorded width it reads "python --version"; at a wider one the
     * erase takes the prompt and command with it.
     */
    @Test fun aReplayFedAtTheRecordedWidthKeepsALineThatReachedTheMargin() {
        val recording = ShellReplay.Collector().apply {
            add("janeappleseed@Janes-MacBook-Pro16 ~ % ".toByteArray(), 48, 20)
            add("python --".toByteArray())
            add("v \r\u001b[K".toByteArray())
            add("ersion\r\n".toByteArray())
        }.chunks()

        fun replay(e: com.termux.terminal.TerminalEmulator, chunks: List<ShellReplayChunk>): String {
            for (c in chunks) when (c) {
                is ShellReplayChunk.Resize -> e.resize(c.cols, c.rows, 10, 20)
                is ShellReplayChunk.Output -> e.append(c.data, c.data.size)
            }
            return e.screen.getSelectedText(0, 0, e.mColumns - 1, e.mRows - 1)
        }

        val atRecordedWidth = replay(ShellEmulators.create(Sink(), 80, 24, 10, 20, 1000), recording)
        assertTrue(atRecordedWidth, atRecordedWidth.contains("janeappleseed@Janes-MacBook-Pro16 ~ % python --version"))

        val output = recording.filterIsInstance<ShellReplayChunk.Output>()
        val atViewWidth = replay(ShellEmulators.create(Sink(), 80, 24, 10, 20, 1000), output)
        assertFalse(atViewWidth, atViewWidth.contains("python"))
    }

    @Test fun anOlderMacsReplayStartsAtTheEntrysSize() {
        val entry = ShellHistoryEntry("a", "zsh", "iPhone", startedAt = 0.0, bytes = 1, cols = 48, rows = 20)
        val plain = listOf<ShellReplayChunk>(ShellReplayChunk.Output("x".toByteArray()))
        assertEquals(listOf(ShellReplayChunk.Resize(48, 20)) + plain, ShellFormat.replayWithStartSize(plain, entry))
        assertEquals(plain, ShellFormat.replayWithStartSize(plain, entry.copy(cols = null)))
        assertEquals(plain, ShellFormat.replayWithStartSize(plain, null))
        val sized = listOf(ShellReplayChunk.Resize(100, 30)) + plain
        assertEquals(sized, ShellFormat.replayWithStartSize(sized, entry))
    }

    @Test fun usesTheAppColours() {
        val e = ShellEmulators.create(Sink(), 80, 24, 10, 20, 1000)
        assertEquals(ShellEmulators.BACKGROUND, e.mColors.mCurrentColors[com.termux.terminal.TextStyle.COLOR_INDEX_BACKGROUND])
    }
}
