package dev.dpatel.passthrough.ui.shell

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Spacer
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import dev.dpatel.passthrough.ui.PTCircleIconButton
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.East
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.North
import androidx.compose.material.icons.filled.South
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.West
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTColors
import dev.dpatel.passthrough.ui.lock.HideFromCapture
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** What the terminal screen does once it knows its size; saveable as a string. */
object TerminalIntent {
    const val NEW = "new"
    /** Show the active session again (after rotation): its replay refills the new terminal. */
    const val RESUME = "resume"
    fun attach(session: String) = "attach:$session"
}

/**
 * Connects a live terminal view to [ShellViewModel]: shows one session at a
 * time, clears before each (re)attach so replays don't stack, and forwards
 * input and size changes. Mirrors ShellTerminalController on iOS.
 */
class ShellTerminalController(context: Context, private val vm: ShellViewModel) : ShellStreamListener {
    val view = ShellTerminalView(context, readOnly = false, transcriptRows = 10_000)
    var ctrl by mutableStateOf(false)
        private set
    var menu by mutableStateOf(false)
    /** The session whose output the terminal shows. */
    var shown by mutableStateOf<String?>(null)
        private set
    /** The shown session ended (or its tab closed): its output is a read-only log. */
    var readOnly by mutableStateOf(false)
        private set

    init {
        view.onInput = { data ->
            val active = vm.activeSession.value
            if (active != null && active == shown) vm.send(data)
        }
        // A read-only log (ended session) has nothing on the Mac to resize.
        view.onResize = { cols, rows -> if (vm.activeSession.value != null && !readOnly) vm.resize(cols, rows) }
        view.onCtrlChanged = { ctrl = it }
        view.onLongPress = { menu = true }
        view.macName = { vm.macs.value.firstOrNull { it.macID == vm.selectedMacID.value }?.macName ?: "your Mac" }
    }

    /** Runs the screen's opening request once the terminal has its real size. */
    fun start(intent: String, started: () -> Unit) {
        view.afterLayout { cols, rows ->
            when {
                intent == TerminalIntent.NEW -> vm.newSession(cols, rows)
                intent.startsWith("attach:") -> vm.attach(intent.removePrefix("attach:"), cols, rows)
                else -> vm.activeSession.value?.let { vm.attach(it, cols, rows) }
            }
            started()
            if (!readOnly) view.showKeyboard()
        }
    }

    /** Re-decides whether the terminal takes input, after sessions ended or tabs closed. */
    fun update(ended: ShellEndedSessions, openTabs: List<String>) {
        readOnly = !ended.isWritable(shown, openTabs)
        view.setReadOnly(readOnly)
    }

    fun newSession() = vm.newSession(view.columns, view.rows)

    /** Shows [id], attaching to it (and so taking it back from another device). */
    fun attach(id: String) = vm.attach(id, view.columns, view.rows)

    override fun streamStarting(session: String, replay: Boolean) {
        shown = session
        view.replaying = false
        view.reset()
        view.replaying = replay
        // An ended session's replay is its log: show it read-only.
        update(vm.ended.value, vm.openTabs.value)
    }

    override fun output(session: String, data: ByteArray) {
        if (session == shown) view.feed(data)
    }

    override fun replayFinished(session: String) {
        if (session == shown) view.replaying = false
    }
}

/** The full-screen terminal: session tabs, the terminal and its key row. */
@Composable
fun TerminalScreen(vm: ShellViewModel, intent: String, onIntentStarted: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val controller = remember { ShellTerminalController(context, vm) }
    val startIntent = remember { intent }
    val rootView = LocalView.current
    DisposableEffect(controller) {
        vm.addListener(controller)
        onDispose {
            vm.removeListener(controller)
            // Leaving the terminal: don't leave its keyboard over Home. The terminal view may
            // already be detached here; the window's root view is not.
            context.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
                ?.hideSoftInputFromWindow(rootView.windowToken, 0)
        }
    }
    LaunchedEffect(controller) { controller.start(startIntent, onIntentStarted) }
    LaunchedEffect(controller) {
        combine(vm.ended, vm.openTabs, ::Pair).collect { (ended, tabs) -> controller.update(ended, tabs) }
    }
    DarkSystemBars()
    HideFromCapture()

    val reach by vm.reach.collectAsStateWithLifecycle()
    val active by vm.activeSession.collectAsStateWithLifecycle()
    val detached by vm.detachedSession.collectAsStateWithLifecycle()
    val lastError by vm.lastError.collectAsStateWithLifecycle()
    val fromAnywhere by vm.triedFromAnywhere.collectAsStateWithLifecycle()
    val ended by vm.ended.collectAsStateWithLifecycle()
    /** Closes [id]'s tab and shows another, or leaves the terminal when none is left. */
    val closeTab = { id: String ->
        val wasShown = id == controller.shown
        vm.close(id)
        if (wasShown) {
            val next = vm.openTabs.value.lastOrNull()
            if (next == null) onClose() else if (vm.reach.value == ShellReach.READY) controller.attach(next)
        }
    }
    // The tab on screen: the attached one, or the one another device took.
    val current = active ?: detached

    CompositionLocalProvider(LocalPT provides PTColors(dark = true)) {
        Box(Modifier.fillMaxSize().background(Color(ShellTerminalView.BACKGROUND))) {
            BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                // Landscape with the keyboard up leaves little height: give it to the terminal
                // (the tabs come back when the keyboard goes; back still closes the terminal).
                val tight = maxHeight < 300.dp
                val compactKeys = maxHeight < 480.dp
                Column(Modifier.fillMaxSize()) {
                    if (!tight) TabStrip(vm, controller, current, reach, ended, onClose, closeTab)
                    // Above the log rather than over it: an ended session's output stays fully readable.
                    controller.shown?.let { id ->
                        ended.banner(id)?.let { text ->
                            Box(Modifier.padding(horizontal = 12.dp).padding(bottom = 8.dp)) {
                                EndedBanner(text, enabled = reach == ShellReach.READY, onNewSession = { controller.newSession() }, onCloseTab = { closeTab(id) })
                            }
                        }
                    }
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        AndroidView(factory = { controller.view }, modifier = Modifier.fillMaxSize().padding(horizontal = 4.dp).clipToBounds())
                        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            detached?.takeIf { it == current }?.let { id ->
                                DetachedBanner(enabled = reach == ShellReach.READY) { controller.attach(id) }
                            }
                            val status = when (reach) {
                                ShellReach.READY -> null
                                ShellReach.CONNECTING -> "Connecting…"
                                else -> reach.message(fromAnywhere)
                            }
                            status?.let {
                                StatusBanner(
                                    it, spinner = reach == ShellReach.CONNECTING, warning = reach == ShellReach.UNREACHABLE,
                                    onRetry = if (reach == ShellReach.UNREACHABLE) vm::connect else null,
                                )
                            }
                            lastError?.message()?.let { StatusBanner(it, warning = true) }
                        }
                        TerminalMenu(controller)
                    }
                    if (!controller.readOnly) {
                        val context = LocalContext.current
                        ExtraKeyRow(controller.ctrl, compactKeys) { if (it == ExtraKey.PASTE) pasteClipboard(context, controller) else controller.view.press(it) }
                    }
                }
            }
        }
    }
}

/** Light status and navigation bar icons over the terminal's dark background, restored on the way out. */
@Composable
internal fun DarkSystemBars() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = view.context.findActivity()?.window
        val insets = window?.let { WindowCompat.getInsetsController(it, view) }
        val status = insets?.isAppearanceLightStatusBars
        val nav = insets?.isAppearanceLightNavigationBars
        insets?.isAppearanceLightStatusBars = false
        insets?.isAppearanceLightNavigationBars = false
        onDispose {
            status?.let { insets.isAppearanceLightStatusBars = it }
            nav?.let { insets.isAppearanceLightNavigationBars = it }
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

// Tabs

@Composable
private fun TabStrip(
    vm: ShellViewModel,
    controller: ShellTerminalController,
    current: String?,
    reach: ShellReach,
    ended: ShellEndedSessions,
    onClose: () -> Unit,
    onCloseTab: (String) -> Unit,
) {
    val c = LocalPT.current
    val tabs by vm.openTabs.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    LaunchedEffect(current, tabs) {
        val i = tabs.indexOf(current)
        if (i >= 0) listState.animateScrollToItem(i)
    }
    Row(
        Modifier.fillMaxWidth().padding(start = 6.dp, end = 12.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        PTCircleIconButton(Icons.Filled.KeyboardArrowDown, "Close terminal", onClose, size = 38.dp, iconSize = 22.dp)
        LazyRow(Modifier.weight(1f), state = listState, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            items(tabs, key = { it }) { id ->
                Tab(vm, controller, id, selected = id == current, enabled = reach == ShellReach.READY, isEnded = ended.isEnded(id), onCloseTab = onCloseTab)
            }
            item(key = "+") {
                val enabled = reach == ShellReach.READY
                Box(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(PT.accentEnd.copy(alpha = if (enabled) 0.16f else 0.07f), CircleShape)
                        .clickable(enabled = enabled, role = Role.Button) { controller.newSession() }
                        .semantics { contentDescription = "New session" },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Add, null, tint = PT.accentEnd.copy(alpha = if (enabled) 1f else 0.4f), modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Tab(
    vm: ShellViewModel,
    controller: ShellTerminalController,
    id: String,
    selected: Boolean,
    enabled: Boolean,
    isEnded: Boolean,
    onCloseTab: (String) -> Unit,
) {
    val c = LocalPT.current
    val sessions by vm.sessions.collectAsStateWithLifecycle()
    val info = sessions.firstOrNull { it.id == id }
    val running = !isEnded && (info?.running ?: false)
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                // 48 dp to touch, a slim chip to see.
                .minimumInteractiveComponentSize()
                .clip(CircleShape)
                .background(if (selected) PT.accentEnd.copy(alpha = 0.18f) else c.fill, CircleShape)
                .then(if (selected) Modifier.border(1.dp, PT.accentEnd.copy(alpha = 0.45f), CircleShape) else Modifier)
                .combinedClickable(
                    enabled = enabled,
                    onClick = { if (id != vm.activeSession.value) controller.attach(id) },
                    onLongClick = { menu = true },
                )
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .alpha(if (isEnded) 0.55f else 1f)
                .semantics { if (isEnded) stateDescription = "Ended" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.size(6.dp).background(if (running) PT.success else c.secondary.copy(alpha = 0.5f), CircleShape))
            Text(info?.title ?: "Session", style = PT.display(13.sp, FontWeight.SemiBold), color = if (selected) PT.accentEnd else c.secondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 160.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (isEnded) {
                DropdownMenuItem(
                    text = { Text("Close tab") },
                    leadingIcon = { Icon(Icons.Filled.Close, null) },
                    onClick = { menu = false; onCloseTab(id) },
                )
            } else {
                DropdownMenuItem(
                    text = { Text("End session", color = PT.danger) },
                    leadingIcon = { Icon(Icons.Filled.Close, null, tint = PT.danger) },
                    onClick = { menu = false; vm.close(id) },
                )
            }
        }
    }
}

// Banners

@Composable
private fun Banner(content: @Composable RowScope.() -> Unit) {
    val c = LocalPT.current
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().background(Color(0xF21C1F2B), shape).border(1.dp, c.cardBorder, shape).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), content = content,
    )
}

@Composable
private fun BannerColumn(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    val c = LocalPT.current
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.fillMaxWidth().background(Color(0xF21C1F2B), shape).border(1.dp, c.cardBorder, shape)
            .padding(start = 14.dp, end = 8.dp, top = 12.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp), content = content,
    )
}

@Composable
private fun DetachedBanner(enabled: Boolean, onTakeBack: () -> Unit) {
    val c = LocalPT.current
    Banner {
        Icon(Icons.AutoMirrored.Filled.Logout, null, tint = PT.warning, modifier = Modifier.size(18.dp))
        Text("Opened on another device", style = PT.display(14.sp, FontWeight.SemiBold), color = c.primary, modifier = Modifier.weight(1f))
        ShellPillButton(onClick = onTakeBack, enabled = enabled) { Text("Take back", style = PT.display(13.sp, FontWeight.Bold)) }
    }
}

/** Over an ended session's log: why it no longer takes input, and where to go next. */
@Composable
private fun EndedBanner(text: String, enabled: Boolean, onNewSession: () -> Unit, onCloseTab: () -> Unit) {
    val c = LocalPT.current
    BannerColumn {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.Lock, null, tint = c.secondary, modifier = Modifier.size(16.dp))
            Text(text, style = PT.display(14.sp, FontWeight.SemiBold), color = c.primary, modifier = Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), modifier = Modifier.fillMaxWidth()) {
            ShellPillButton(onClick = onCloseTab) { Text("Close tab", style = PT.display(13.sp, FontWeight.Bold)) }
            ShellPillButton(onClick = onNewSession, enabled = enabled) {
                Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(4.dp))
                Text("New session", style = PT.display(13.sp, FontWeight.Bold))
            }
        }
    }
}

@Composable
private fun StatusBanner(text: String, spinner: Boolean = false, warning: Boolean = false, onRetry: (() -> Unit)? = null) {
    val c = LocalPT.current
    Banner {
        if (spinner) CircularProgressIndicator(Modifier.size(16.dp), color = PT.accentEnd, strokeWidth = 2.dp)
        if (warning) Icon(Icons.Filled.Warning, null, tint = PT.warning, modifier = Modifier.size(16.dp))
        Text(text, style = PT.display(14.sp, FontWeight.Normal), color = c.primary.copy(alpha = 0.85f), modifier = Modifier.weight(1f))
        onRetry?.let { ShellPillButton(onClick = it) { Text("Try again", style = PT.display(13.sp, FontWeight.Bold)) } }
    }
}

/** Long-press menu: paste into the shell, or copy what's on screen. */
@Composable
private fun TerminalMenu(controller: ShellTerminalController) {
    val context = LocalContext.current
    DropdownMenu(expanded = controller.menu, onDismissRequest = { controller.menu = false }) {
        val clipboard = remember { context.getSystemService(ClipboardManager::class.java) }
        DropdownMenuItem(
            text = { Text("Paste") },
            leadingIcon = { Icon(Icons.Filled.ContentPaste, null) },
            enabled = !controller.readOnly && clipboard?.hasPrimaryClip() == true,
            onClick = {
                controller.menu = false
                pasteClipboard(context, controller)
            },
        )
        DropdownMenuItem(
            text = { Text("Copy screen") },
            leadingIcon = { Icon(Icons.Filled.ContentCopy, null) },
            onClick = {
                controller.menu = false
                clipboard?.setPrimaryClip(android.content.ClipData.newPlainText("Terminal", controller.view.visibleText()))
            },
        )
    }
}

/** Pastes the clipboard's text into the shell (bracketed when the program asked for it). */
private fun pasteClipboard(context: Context, controller: ShellTerminalController) {
    val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
    clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()?.let(controller.view::paste)
}

// Key row

/**
 * The keys above the keyboard: esc, ctrl (applies to the next key, key-row
 * keys included), tab, arrows (repeat while held), `|`, `~` and paste. Styled like
 * the app's tinted capsule buttons.
 */
@Composable
private fun ExtraKeyRow(ctrl: Boolean, compact: Boolean, onKey: (ExtraKey) -> Unit) {
    // Each key is 48 dp tall to touch (44 when space is short: landscape with the keyboard up)
    // around a slimmer capsule, and the row spans the width, so keys stay wide on any screen.
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        ExtraKey.entries.forEach { key -> KeyButton(key, selected = key == ExtraKey.CTRL && ctrl, compact, onKey) }
    }
}

@Composable
private fun RowScope.KeyButton(key: ExtraKey, selected: Boolean, compact: Boolean, onKey: (ExtraKey) -> Unit) {
    val view = LocalView.current
    val press = { k: ExtraKey ->
        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        onKey(k)
    }
    Box(
        Modifier
            .weight(1f)
            .height(if (compact) 44.dp else 48.dp)
            .semantics {
                contentDescription = key.description
                role = Role.Button
                if (key == ExtraKey.CTRL) stateDescription = if (selected) "On" else "Off"
            }
            .pointerInput(key) {
                detectTapGestures(onPress = {
                    if (key.isArrow) {
                        coroutineScope {
                            val repeat = launch {
                                press(key)
                                delay(500)
                                while (true) {
                                    press(key)
                                    delay(80)
                                }
                            }
                            tryAwaitRelease()
                            repeat.cancel()
                        }
                    } else if (tryAwaitRelease()) {
                        press(key)
                    }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.fillMaxWidth().height(if (compact) 34.dp else 38.dp)
                .background(if (selected) PT.accentEnd else PT.accentEnd.copy(alpha = 0.14f), RoundedCornerShape(10.dp)),
        )
        val tint = if (selected) Color.White else PT.accentEnd
        val icon: ImageVector? = when (key) {
            ExtraKey.LEFT -> Icons.Filled.West
            ExtraKey.UP -> Icons.Filled.North
            ExtraKey.DOWN -> Icons.Filled.South
            ExtraKey.RIGHT -> Icons.Filled.East
            ExtraKey.PASTE -> Icons.Filled.ContentPaste
            else -> null
        }
        if (icon != null) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(17.dp))
        } else {
            // Fixed size (not scaled with the font setting): the row must keep all ten keys on one line.
            Text(key.label.orEmpty(), color = tint, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold,
                fontSize = with(LocalDensity.current) { 14.dp.toSp() }, maxLines = 1)
        }
    }
}
