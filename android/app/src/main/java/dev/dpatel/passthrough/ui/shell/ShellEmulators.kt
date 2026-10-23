package dev.dpatel.passthrough.ui.shell

import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle

/** Makes the emulators behind [ShellTerminalView]: the app's colours, and a client that logs nothing. */
object ShellEmulators {
    const val BACKGROUND = 0xFF0D0F17.toInt()
    const val FOREGROUND = 0xFFE6E6E6.toInt()
    /** PT.accentStart. */
    const val CURSOR = 0xFF40E0D1.toInt()

    init {
        // The scheme every emulator (and every reset) starts from.
        TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_BACKGROUND] = BACKGROUND
        TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_FOREGROUND] = FOREGROUND
        TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR] = CURSOR
    }

    fun create(output: TerminalOutput, columns: Int, rows: Int, cellWidth: Int, cellHeight: Int, transcriptRows: Int): TerminalEmulator =
        TerminalEmulator(output, columns, rows, cellWidth, cellHeight, transcriptRows, QuietClient)

    /**
     * The emulator reports parse problems (with the offending bytes) through
     * its client, or to logcat without one: this client drops everything.
     */
    private object QuietClient : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) = Unit
        override fun onTitleChanged(changedSession: TerminalSession) = Unit
        override fun onSessionFinished(finishedSession: TerminalSession) = Unit
        override fun onCopyTextToClipboard(session: TerminalSession, text: String?) = Unit
        override fun onPasteTextFromClipboard(session: TerminalSession?) = Unit
        override fun onBell(session: TerminalSession) = Unit
        override fun onColorsChanged(session: TerminalSession) = Unit
        override fun onTerminalCursorStateChange(state: Boolean) = Unit
        override fun getTerminalCursorStyle(): Int? = null
        override fun logError(tag: String?, message: String?) = Unit
        override fun logWarn(tag: String?, message: String?) = Unit
        override fun logInfo(tag: String?, message: String?) = Unit
        override fun logDebug(tag: String?, message: String?) = Unit
        override fun logVerbose(tag: String?, message: String?) = Unit
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) = Unit
        override fun logStackTrace(tag: String?, e: Exception?) = Unit
    }
}
