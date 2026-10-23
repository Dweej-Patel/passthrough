package dev.dpatel.passthrough.ui.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import dev.dpatel.passthrough.ui.PTTopBar
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.ShellHistoryEntry
import dev.dpatel.passthrough.core.ShellReplay
import dev.dpatel.passthrough.core.ShellReplayChunk
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTBackground
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.PTColors
import dev.dpatel.passthrough.ui.PTSectionTitle
import dev.dpatel.passthrough.ui.PTStatusDot
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.yield
import kotlin.coroutines.resume
import java.text.DateFormat
import java.util.Date

/** Every session the Mac recorded, newest first; each opens a read-only replay. */
@Composable
fun ShellHistoryScreen(vm: ShellViewModel, onDone: () -> Unit) {
    var openID by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { vm.loadHistory() }
    val history by vm.history.collectAsStateWithLifecycle()
    BackHandler(enabled = openID != null) { openID = null }
    val open = openID
    if (open != null) {
        TranscriptScreen(vm, open, history.firstOrNull { it.id == open }, onBack = { openID = null })
    } else {
        HistoryList(vm, history, onDone) { openID = it }
    }
}

@Composable
private fun HistoryList(vm: ShellViewModel, history: List<ShellHistoryEntry>, onDone: () -> Unit, onOpen: (String) -> Unit) {
    val c = LocalPT.current
    val sessions by vm.sessions.collectAsStateWithLifecycle()
    val reach by vm.reach.collectAsStateWithLifecycle()
    val loading by vm.historyLoading.collectAsStateWithLifecycle()
    PTBackground(glow = 0.45f) {
        Column(Modifier.windowInsetsPadding(WindowInsets.safeDrawing)) {
            PTTopBar("History", onDone = onDone)
            Column(Modifier.verticalScroll(rememberScrollState()).fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp).padding(horizontal = 18.dp).padding(top = 8.dp, bottom = 32.dp)) {
                PTCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        PTSectionTitle("Sessions on this Mac", icon = Icons.Filled.History)
                        when {
                            history.isNotEmpty() -> Column {
                                history.sortedByDescending { it.startedAt }.forEach { entry ->
                                    val running = entry.endedAt == null && sessions.any { it.id == entry.id && it.running }
                                    HistoryRow(entry, running) { onOpen(entry.id) }
                                }
                            }
                            loading || reach == ShellReach.CONNECTING -> Row(
                                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                CircularProgressIndicator(Modifier.size(18.dp), color = PT.accentEnd, strokeWidth = 2.dp)
                                Text("Loading history…", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                            }
                            reach != ShellReach.READY -> Text(
                                "Connect to your Mac to see its history. ${reach.message(fromAnywhere = false).orEmpty()}".trim(),
                                style = PT.display(15.sp, FontWeight.Normal), color = c.secondary,
                            )
                            else -> Text(
                                "No sessions yet. Sessions you open from any device are recorded on the Mac and show up here.",
                                style = PT.display(15.sp, FontWeight.Normal), color = c.secondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryRow(entry: ShellHistoryEntry, running: Boolean, onClick: () -> Unit) {
    val c = LocalPT.current
    val started = remember(entry.startedAt) {
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date((entry.startedAt * 1000).toLong()))
    }
    val detail = "${ShellFormat.historyStatus(entry, running)} · $started · ${entry.phoneLabel}"
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick, role = Role.Button)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PTStatusDot(if (running) PT.success else c.secondary.copy(alpha = 0.5f), running)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(entry.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = c.tertiary, modifier = Modifier.size(20.dp))
    }
}

private enum class Phase { LOADING, LOADED, FAILED }

/** One session's recorded output in a read-only terminal, with find. */
@Composable
private fun TranscriptScreen(vm: ShellViewModel, id: String, entry: ShellHistoryEntry?, onBack: () -> Unit) {
    val context = LocalContext.current
    // Read-only: never answers queries in the recording, never touches the clipboard.
    val view = remember(id) { ShellTerminalView(context, readOnly = true, transcriptRows = 50_000) }
    var phase by remember(id) { mutableStateOf(Phase.LOADING) }
    var attempt by remember(id) { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var notFound by remember { mutableStateOf(false) }

    LaunchedEffect(id, attempt) {
        phase = Phase.LOADING
        view.reset()
        val replay = vm.transcript(id)?.let { ShellFormat.replayWithStartSize(it, entry) }
        if (replay == null) {
            phase = Phase.FAILED
            return@LaunchedEffect
        }
        phase = Phase.LOADED
        // Fed once the terminal is laid out, at the sizes the recording had (never the
        // screen's own: shells draw for their terminal's width), with the font fitted
        // once to the largest; in pieces, so a long recording doesn't freeze the screen.
        suspendCancellableCoroutine { cont -> view.afterLayout { _, _ -> if (cont.isActive) cont.resume(Unit) } }
        ShellReplay.largestGrid(replay)?.let { (cols, rows) -> view.fitGrid(cols, rows) }
        for (chunk in replay) {
            when (chunk) {
                is ShellReplayChunk.Resize -> view.setGrid(chunk.cols, chunk.rows)
                is ShellReplayChunk.Output -> {
                    val data = chunk.data
                    var offset = 0
                    while (offset < data.size) {
                        val end = minOf(offset + 65_536, data.size)
                        view.feed(data.copyOfRange(offset, end))
                        offset = end
                        yield()
                    }
                }
            }
        }
    }

    fun find(forward: Boolean) {
        if (query.isEmpty()) return
        notFound = !view.find(query, forward)
    }

    DarkSystemBars()
    CompositionLocalProvider(LocalPT provides PTColors(dark = true)) {
        val c = LocalPT.current
        Box(Modifier.fillMaxSize().background(Color(ShellTerminalView.BACKGROUND))) {
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                PTTopBar(entry?.title ?: "Session", onBack = onBack, backLabel = "History")
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        Modifier.weight(1f).heightIn(min = 44.dp).background(c.card, CircleShape).border(1.dp, c.cardBorder, CircleShape)
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Filled.Search, null, tint = c.secondary, modifier = Modifier.size(16.dp))
                        BasicTextField(
                            value = query, onValueChange = { query = it; notFound = false }, singleLine = true,
                            enabled = phase == Phase.LOADED,
                            textStyle = PT.display(15.sp, FontWeight.Normal).copy(color = c.primary),
                            cursorBrush = SolidColor(PT.accentEnd),
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = { find(forward = true) }),
                            modifier = Modifier.weight(1f),
                            decorationBox = { inner ->
                                if (query.isEmpty()) Text("Search this session", style = PT.display(15.sp, FontWeight.Normal), color = c.tertiary)
                                inner()
                            },
                        )
                        if (notFound) Text("No matches", style = PT.display(12.sp, FontWeight.Normal), color = PT.warning,
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    }
                    Box(Modifier.semantics { contentDescription = "Previous match" }) {
                        ShellPillButton(onClick = { find(forward = false) }, enabled = phase == Phase.LOADED) {
                            Icon(Icons.Filled.KeyboardArrowUp, null, modifier = Modifier.size(20.dp))
                        }
                    }
                    Box(Modifier.semantics { contentDescription = "Next match" }) {
                        ShellPillButton(onClick = { find(forward = true) }, enabled = phase == Phase.LOADED) {
                            Icon(Icons.Filled.KeyboardArrowDown, null, modifier = Modifier.size(20.dp))
                        }
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize().padding(horizontal = 4.dp).clipToBounds())
                    when (phase) {
                        Phase.LOADING -> CircularProgressIndicator(Modifier.size(24.dp), color = c.secondary, strokeWidth = 2.dp)
                        Phase.FAILED -> Column(
                            Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text("Couldn't load this session", style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary, textAlign = TextAlign.Center)
                            Text("The Mac didn't send its output. Check the connection and try again.", style = PT.display(15.sp, FontWeight.Normal),
                                color = c.secondary, textAlign = TextAlign.Center)
                            ShellPillButton(onClick = { attempt++ }) { Text("Try again", style = PT.display(13.sp, FontWeight.Bold)) }
                        }
                        Phase.LOADED -> Unit
                    }
                }
            }
        }
    }
}
