package dev.dpatel.passthrough.ui.shell

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.PersistableBundle
import android.text.InputType
import android.util.TypedValue
import android.view.GestureDetector
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Scroller
import android.widget.Toast
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TextStyle
import com.termux.view.TerminalRenderer
import dev.dpatel.passthrough.core.ShellReplay
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * A terminal with no local process: Termux's [TerminalEmulator] parses what
 * the Mac sends ([feed]) and Termux's [TerminalRenderer] draws it; what the
 * user types, and the emulator's own replies, leave through [onInput].
 *
 * Termux's `TerminalView` can't be used here: it needs a `TerminalSession`
 * (a final class that starts a local shell on first layout) and dereferences
 * it for input, copy and alt-screen scrolling.
 *
 * While [replaying] (scrollback replayed on attach), replies the emulator
 * generates while parsing (device attributes, cursor position, colors…) and
 * OSC 52 clipboard writes are dropped, so old queries don't reach the shell
 * as junk input. A [readOnly] view never sends anything and never touches
 * the clipboard. Nothing here logs what passes through it.
 */
@SuppressLint("ViewConstructor")
class ShellTerminalView(context: Context, readOnly: Boolean, private val transcriptRows: Int) : View(context) {
    /** Whether input is off; switched at runtime by [setReadOnly] (a live session that ended). */
    var readOnly = readOnly
        private set
    /** The cursor isn't drawn: the session ended, so nothing will be typed at it. */
    private var cursorHidden = readOnly
    /** Bytes for the shell: keystrokes, pastes and the emulator's replies. */
    var onInput: ((ByteArray) -> Unit)? = null
    /** The grid changed after its first layout. */
    var onResize: ((Int, Int) -> Unit)? = null
    var onCtrlChanged: ((Boolean) -> Unit)? = null
    var onLongPress: (() -> Unit)? = null
    /** Output being fed is a replay: see the class comment. */
    var replaying = false
    /** The Mac this terminal shows, for "Copied from …" when a program there copies. */
    var macName: () -> String = { "your Mac" }

    var ctrlLatched = false
        private set

    private var feeding = false
    private val baseTextSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 13f, resources.displayMetrics).toInt()
    private var renderer = TerminalRenderer(baseTextSize, Typeface.MONOSPACE)
    private var lineSpacing = 0
    private var lineSpacingAndAscent = 0

    init { measure(baseTextSize) }

    /** Same metrics as TerminalRenderer computes (its own fields aren't public). */
    private fun measure(size: Int) {
        val paint = Paint().apply { typeface = Typeface.MONOSPACE; isAntiAlias = true; textSize = size.toFloat() }
        lineSpacing = ceil(paint.fontSpacing).toInt()
        lineSpacingAndAscent = lineSpacing + ceil(paint.ascent()).toInt()
    }

    /** A replay's grid ([setGrid]): the view's size no longer changes it. */
    private var fixedGrid = false
    /** How far a grid wider than the view is panned sideways, in pixels. */
    private var panX = 0f

    private val output = Output()
    /** Replaced by [reset]: every stream starts from a clean emulator. */
    var emulator: TerminalEmulator = ShellEmulators.create(output, 80, 24, renderer.fontWidth.toInt(), renderer.fontLineSpacing, transcriptRows)
        private set
    private val applySize = Runnable { applySize() }

    /** The top row shown: 0 is the live screen, negative is scrolled back. */
    private var topRow = 0
    private var scrollRemainder = 0f
    private val scroller = Scroller(context)
    private var laidOut = false
    private val whenLaidOut = ArrayList<(Int, Int) -> Unit>()
    /** Search highlight: row, column of the match start, and its length. */
    private var match: Triple<Int, Int, Int>? = null
    private var combiningAccent = 0

    val columns: Int get() = emulator.mColumns
    val rows: Int get() = emulator.mRows

    init {
        isFocusable = !readOnly
        isFocusableInTouchMode = !readOnly
        importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
    }

    /**
     * For a replay: makes the font smaller, if needed (not below
     * [MIN_REPLAY_TEXT_SP]), so a [cols]×[rows] grid fits the view; a grid that
     * still doesn't fit pans sideways. Call once laid out, before feeding.
     */
    fun fitGrid(cols: Int, rows: Int) {
        val minimum = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, MIN_REPLAY_TEXT_SP, resources.displayMetrics) / baseTextSize
        val scale = ShellReplay.fitScale(
            cols * renderer.fontWidth, (rows * lineSpacing + lineSpacingAndAscent).toFloat(),
            width.toFloat(), height.toFloat(), minimum,
        )
        if (scale >= 1f) return
        val size = max(1, (baseTextSize * scale).toInt())
        renderer = TerminalRenderer(size, Typeface.MONOSPACE)
        measure(size)
        emulator.resize(emulator.mColumns, emulator.mRows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
        invalidate()
    }

    /**
     * Fixes the grid at [cols]×[rows] from now on, whatever the view's size: a
     * replay is drawn at the size the recording had, since shells draw for their
     * terminal's width (zsh relies on autowrap at the right margin).
     */
    fun setGrid(cols: Int, rows: Int) {
        fixedGrid = true
        removeCallbacks(applySize)
        if (cols != emulator.mColumns || rows != emulator.mRows) {
            emulator.resize(cols, rows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
            topRow = topRow.coerceIn(-emulator.screen.activeTranscriptRows, 0)
        }
        panX = panX.coerceIn(0f, maxPan())
        invalidate()
    }

    private fun maxPan(): Float = if (fixedGrid) max(0f, columns * renderer.fontWidth - width) else 0f

    /** Runs [body] with the grid size once the view has its real size (now, if it has). */
    fun afterLayout(body: (Int, Int) -> Unit) {
        if (laidOut) body(columns, rows) else whenLaidOut += body
    }

    fun feed(data: ByteArray, length: Int = data.size) {
        // Replies to queries are written synchronously from inside append; keystrokes never are.
        feeding = true
        try {
            emulator.append(data, length)
        } finally {
            feeding = false
        }
        val shift = emulator.scrollCounter
        emulator.clearScrollCounter()
        if (shift != 0) {
            // Keep looking at the same lines while scrolled back; follow the output otherwise.
            if (topRow < 0) topRow = max(-emulator.screen.activeTranscriptRows, topRow - shift)
            match = match?.let { (row, col, len) -> Triple(row - shift, col, len) }
        }
        invalidate()
    }

    /**
     * Starts over with a fresh emulator at the current size, so a replay doesn't
     * stack on old output and inherits no state (RIS alone would leave a program's
     * alternate screen, and so arrow-key scrolling, active).
     */
    fun reset() {
        emulator = ShellEmulators.create(output, emulator.mColumns, emulator.mRows, renderer.fontWidth.toInt(), renderer.fontLineSpacing, transcriptRows)
        topRow = 0
        match = null
        combiningAccent = 0
        invalidate()
    }

    fun setCtrl(on: Boolean) {
        if (ctrlLatched == on) return
        ctrlLatched = on
        onCtrlChanged?.invoke(on)
    }

    /** A key from the key row. Ctrl latches until the next key, which it modifies. */
    fun press(key: ExtraKey) {
        if (readOnly) return
        if (key == ExtraKey.CTRL) return setCtrl(!ctrlLatched)
        val ctrl = takeCtrl()
        TerminalKeys.extraKey(key, emulator.isCursorKeysApplicationMode, ctrl)?.let(::send)
    }

    /** Pastes [text] (bracketed when the program asked for it). */
    fun paste(text: String) {
        if (readOnly || text.isEmpty()) return
        topRow = 0
        emulator.paste(text)
    }

    /** The text on screen (as scrolled), trailing spaces trimmed. */
    fun visibleText(): String = emulator.screen.getSelectedText(0, topRow, columns, topRow + rows - 1).trimEnd()

    /** Moves to the next (or previous) match of [query]; false when there is none. */
    fun find(query: String, forward: Boolean): Boolean {
        val screen = emulator.screen
        val first = -screen.activeTranscriptRows
        val lines = (first until rows).map { screen.getSelectedText(0, it, columns, it, false) }
        val from = match?.let { (row, col, _) -> (row - first) to col }
        val found = findInLines(lines, query, from, forward)
        if (found == null) {
            match = null
            invalidate()
            return false
        }
        val row = found.first + first
        match = Triple(row, found.second, query.length)
        if (row < topRow || row >= topRow + rows) topRow = (row - rows / 2).coerceIn(first, 0)
        val x = found.second * renderer.fontWidth
        if (x < panX || x + query.length * renderer.fontWidth > panX + width) panX = (x - width / 3f).coerceIn(0f, maxPan())
        invalidate()
        return true
    }

    /**
     * Turns input on or off. Read-only hides the keyboard (it can't come back:
     * the view stops being a text editor) and the cursor, and ignores input; the
     * output stays scrollable. Editable makes it focusable again and shows the keyboard.
     */
    fun setReadOnly(value: Boolean) {
        if (value == readOnly) return
        val imm = context.getSystemService(InputMethodManager::class.java)
        readOnly = value
        cursorHidden = value
        isFocusable = !value
        isFocusableInTouchMode = !value
        if (value) {
            setCtrl(false)
            combiningAccent = 0
            imm?.hideSoftInputFromWindow(windowToken, 0)
            clearFocus()
            imm?.restartInput(this)
        } else {
            emulator.setCursorBlinkingEnabled(false)
            imm?.restartInput(this)
            showKeyboard()
        }
        invalidate()
    }

    /** [byUser]: a tap, so an explicit request (an implicit one may be ignored once the user hid the keyboard). */
    fun showKeyboard(byUser: Boolean = false) {
        if (readOnly) return
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)
            ?.showSoftInput(this, if (byUser) 0 else InputMethodManager.SHOW_IMPLICIT)
    }

    // Layout and drawing

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        if (w == 0 || h == 0) return
        removeCallbacks(applySize)
        // The keyboard animates the view's height frame by frame: apply (and tell the Mac)
        // only the settled size. The first layout applies at once.
        if (laidOut) postDelayed(applySize, RESIZE_SETTLE_MS) else applySize()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(applySize)
        super.onDetachedFromWindow()
    }

    private fun applySize() {
        if (width == 0 || height == 0) return
        val cols = max(4, (width / renderer.fontWidth).toInt())
        val newRows = max(4, (height - lineSpacingAndAscent) / lineSpacing)
        panX = panX.coerceIn(0f, maxPan())
        if (!fixedGrid && (cols != emulator.mColumns || newRows != emulator.mRows)) {
            val reflow = cols != emulator.mColumns
            emulator.resize(cols, newRows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
            if (readOnly && !reflow) {
                // Only the height changed (keyboard): keep the reader's place and match.
                topRow = topRow.coerceIn(-emulator.screen.activeTranscriptRows, 0)
            } else {
                topRow = 0
                match = null
            }
            if (laidOut) onResize?.invoke(cols, newRows)
        }
        if (!laidOut) {
            laidOut = true
            val pending = whenLaidOut.toList()
            whenLaidOut.clear()
            pending.forEach { it(columns, rows) }
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        // Fill only this view: drawColor fills the whole clip, which inside Compose can be the
        // entire window and would paint over the tab strip and search bar above the terminal.
        backgroundPaint.color = emulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND]
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), backgroundPaint)
        canvas.save()
        canvas.clipRect(0, 0, width, height)
        if (cursorHidden) {
            // Termux draws the cursor only while its blink state is on.
            emulator.setCursorBlinkingEnabled(true)
            emulator.setCursorBlinkState(false)
        }
        val m = match
        canvas.save()
        canvas.translate(-panX, 0f)
        if (m == null) {
            renderer.render(emulator, canvas, topRow, -1, -1, -1, -1)
        } else {
            val (row, col, len) = m
            renderer.render(emulator, canvas, topRow, row, row, col, min(columns - 1, col + len - 1))
        }
        canvas.restore()
        canvas.restore()
    }

    private val backgroundPaint = Paint()

    // Touch

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean {
            scroller.forceFinished(true)
            scrollRemainder = 0f
            return true
        }

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            showKeyboard(byUser = true)
            return true
        }

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (fixedGrid) {
                val pan = (panX + distanceX).coerceIn(0f, maxPan())
                if (pan != panX) { panX = pan; invalidate() }
            }
            val dy = distanceY + scrollRemainder
            val delta = (dy / lineSpacing).toInt()
            scrollRemainder = dy - delta * lineSpacing
            scrollRows(e2, delta)
            return true
        }

        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
            // Flinging only moves through scrollback; programs on the alternate screen get line by line.
            if (emulator.isMouseTrackingActive || emulator.isAlternateBufferActive) return true
            scroller.fling(0, topRow, 0, -(velocityY * 0.25f).toInt(), 0, 0, -emulator.screen.activeTranscriptRows, 0)
            postOnAnimation(object : Runnable {
                override fun run() {
                    if (!scroller.computeScrollOffset()) return
                    topRow = scroller.currY.coerceIn(-emulator.screen.activeTranscriptRows, 0)
                    invalidate()
                    postOnAnimation(this)
                }
            })
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            onLongPress?.invoke()
        }
    })

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestures.onTouchEvent(event)
        return true
    }

    private fun scrollRows(event: MotionEvent, rowsDown: Int) {
        if (rowsDown == 0) return
        val up = rowsDown < 0
        repeat(abs(rowsDown)) {
            when {
                emulator.isMouseTrackingActive -> if (!readOnly) {
                    val col = (event.x / renderer.fontWidth).toInt() + 1
                    val row = ((event.y - lineSpacingAndAscent) / lineSpacing).toInt() + 1
                    emulator.sendMouseEvent(if (up) TerminalEmulator.MOUSE_WHEELUP_BUTTON else TerminalEmulator.MOUSE_WHEELDOWN_BUTTON, col, row, true)
                }
                // Like other terminals: arrows scroll programs such as less on the alternate screen.
                emulator.isAlternateBufferActive -> if (!readOnly) {
                    send(TerminalKeys.arrow(if (up) ExtraKey.UP else ExtraKey.DOWN, emulator.isCursorKeysApplicationMode, ctrl = false))
                }
                else -> topRow = (topRow + if (up) -1 else 1).coerceIn(-emulator.screen.activeTranscriptRows, 0)
            }
        }
        invalidate()
    }

    // Keyboard

    override fun onCheckIsTextEditor(): Boolean = !readOnly

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        if (readOnly) return null
        // As Termux: TYPE_NULL makes keyboards send plain keys, with no suggestions or autocorrect.
        outAttrs.inputType = InputType.TYPE_NULL
        // Keep commands (and anything typed at a password prompt) out of the keyboard's learning.
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        return object : BaseInputConnection(this, true) {
            override fun finishComposingText(): Boolean {
                super.finishComposingText()
                editable?.let { sendText(it); it.clear() }
                return true
            }

            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                super.commitText(text, newCursorPosition)
                editable?.let { sendText(it); it.clear() }
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                // Some keyboards delete several characters at once this way.
                val delete = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL)
                repeat(beforeLength) { sendKeyEvent(delete) }
                return super.deleteSurroundingText(beforeLength, afterLength)
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (readOnly || event.isSystem) return super.onKeyDown(keyCode, event)
        if (event.action == KeyEvent.ACTION_MULTIPLE && keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            event.characters?.let(::sendText)
            return true
        }
        val meta = event.metaState
        val ctrl = event.isCtrlPressed || ctrlLatched
        val leftAlt = meta and KeyEvent.META_ALT_LEFT_ON != 0
        val rightAlt = meta and KeyEvent.META_ALT_RIGHT_ON != 0
        var keyMod = 0
        if (ctrl) keyMod = keyMod or KeyHandler.KEYMOD_CTRL
        if (event.isAltPressed || leftAlt) keyMod = keyMod or KeyHandler.KEYMOD_ALT
        if (event.isShiftPressed) keyMod = keyMod or KeyHandler.KEYMOD_SHIFT
        if (event.isNumLockOn) keyMod = keyMod or KeyHandler.KEYMOD_NUM_LOCK
        if (!event.isFunctionPressed) {
            val code = KeyHandler.getCode(keyCode, keyMod, emulator.isCursorKeysApplicationMode, emulator.isKeypadApplicationMode)
            if (code != null) {
                takeCtrl()
                send(code.toByteArray(Charsets.UTF_8))
                return true
            }
        }
        // Ctrl and left alt are applied below; right alt composes characters.
        var clear = KeyEvent.META_CTRL_MASK
        if (!rightAlt) clear = clear or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        val result = event.getUnicodeChar(meta and clear.inv())
        if (result == 0) return super.onKeyDown(keyCode, event)
        if (result and KeyCharacterMap.COMBINING_ACCENT != 0) {
            if (combiningAccent != 0) inputCodePoint(combiningAccent, event.isCtrlPressed, leftAlt)
            combiningAccent = result and KeyCharacterMap.COMBINING_ACCENT_MASK
        } else {
            var codePoint = result
            if (combiningAccent != 0) {
                val combined = KeyCharacterMap.getDeadChar(combiningAccent, codePoint)
                if (combined > 0) codePoint = combined
                combiningAccent = 0
            }
            inputCodePoint(codePoint, event.isCtrlPressed, leftAlt)
        }
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        if (readOnly || event.isSystem) super.onKeyUp(keyCode, event) else true

    /** Text from the keyboard, as Termux treats it: newline is return, control characters keep ctrl. */
    private fun sendText(text: CharSequence) {
        var i = 0
        while (i < text.length) {
            val codePoint = Character.codePointAt(text, i)
            i += Character.charCount(codePoint)
            if (codePoint in 0..31 && codePoint != 27) {
                val plain = when (val c = if (codePoint == '\n'.code) '\r'.code else codePoint) {
                    31 -> '_'.code
                    30 -> '^'.code
                    29 -> ']'.code
                    28 -> '\\'.code
                    else -> c + 96
                }
                inputCodePoint(plain, ctrlFromEvent = true, alt = false)
            } else {
                inputCodePoint(codePoint, ctrlFromEvent = false, alt = false)
            }
        }
    }

    private fun inputCodePoint(codePoint: Int, ctrlFromEvent: Boolean, alt: Boolean) {
        val ctrl = takeCtrl() || ctrlFromEvent
        // Bluetooth keyboards send spacing modifiers for these; programs expect the ASCII ones.
        val c = when (codePoint) {
            0x02DC -> '~'.code
            0x02CB -> '`'.code
            0x02C6 -> '^'.code
            else -> codePoint
        }
        send(TerminalKeys.typed(c, ctrl, alt))
    }

    private fun takeCtrl(): Boolean {
        val on = ctrlLatched
        setCtrl(false)
        return on
    }

    /** User input: jumps back to the live screen. */
    private fun send(bytes: ByteArray) {
        if (readOnly) return
        if (topRow != 0) {
            topRow = 0
            invalidate()
        }
        onInput?.invoke(bytes)
    }

    /** Where the emulator writes: its replies, mouse reports and pastes. */
    private inner class Output : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            if (readOnly || (feeding && replaying)) return
            onInput?.invoke(data.copyOfRange(offset, offset + count))
        }

        override fun onCopyTextToClipboard(text: String) {
            // OSC 52 from the shell (Claude Code, tmux, vim). Never from a replay or a read-only transcript.
            if (readOnly || replaying) return
            val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
            val clip = ClipData.newPlainText("Terminal", text)
            // Sensitive: kept out of the clipboard preview and keyboard suggestions. Android 13 has the
            // constant; earlier, keyboards that honour it read the same key spelled out.
            clip.description.extras = PersistableBundle().apply {
                putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
            }
            clipboard.setPrimaryClip(clip)
            // Android 13+ confirms every copy itself; before that, nothing would say a copy happened unasked.
            if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, "Copied from ${macName()}", Toast.LENGTH_SHORT).show()
        }

        // OSC 52 reads would hand the clipboard to the Mac: never answered.
        override fun onPasteTextFromClipboard() = Unit
        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit
        override fun onBell() = Unit
        override fun onColorsChanged() = invalidate()
    }

    companion object {
        /** PTBackground's dark base, so the terminal sits in the app's surfaces. */
        const val BACKGROUND = ShellEmulators.BACKGROUND

        /** Smallest font a replay's grid is shrunk to before it pans instead. */
        private const val MIN_REPLAY_TEXT_SP = 7f

        /** How long a size must hold before it is applied (the keyboard animates for ~250 ms). */
        private const val RESIZE_SETTLE_MS = 120L
    }
}
