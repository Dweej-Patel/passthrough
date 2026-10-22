package dev.dpatel.passthrough.ui.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
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
    PTBackground(glow = 0.45f) {
        Column(Modifier.windowInsetsPadding(WindowInsets.safeDrawing)) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
                Text("History", style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary, modifier = Modifier.align(Alignment.Center))
                Text("Done", style = PT.display(17.sp, FontWeight.Bold), color = PT.accentEnd,
                    modifier = Modifier.align(Alignment.CenterEnd).clickable(onClick = onDone).padding(4.dp))
            }
            Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 18.dp).padding(top = 8.dp, bottom = 32.dp)) {
                PTCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        PTSectionTitle("Sessions", icon = Icons.Filled.History)
                        if (history.isEmpty()) {
                            Text("No sessions recorded yet.", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                        } else {
                            history.sortedByDescending { it.startedAt }.forEach { entry ->
                                val running = entry.endedAt == null && sessions.any { it.id == entry.id && it.running }
                                HistoryRow(entry, running) { onOpen(entry.id) }
                            }
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
    val detail = "$started · ${entry.phoneLabel} · ${ShellFormat.historyStatus(entry, running)}"
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PTStatusDot(if (running) PT.success else c.secondary.copy(alpha = 0.5f), running)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(entry.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = c.tertiary, modifier = Modifier.size(18.dp))
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
    var query by rememberSaveable { mutableStateOf("") }
    var notFound by remember { mutableStateOf(false) }

    LaunchedEffect(id) {
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
                Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 12.dp)) {
                    Row(
                        Modifier.align(Alignment.CenterStart).clickable(onClick = onBack).padding(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null, tint = PT.accentEnd, modifier = Modifier.size(22.dp))
                        Text("History", style = PT.display(17.sp, FontWeight.Normal), color = PT.accentEnd)
                    }
                    Text(entry?.title ?: "Session", style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.align(Alignment.Center).padding(horizontal = 96.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        Modifier.weight(1f).background(c.card, CircleShape).padding(horizontal = 12.dp, vertical = 8.dp),
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
                                if (query.isEmpty()) Text("Search", style = PT.display(15.sp, FontWeight.Normal), color = c.tertiary)
                                inner()
                            },
                        )
                        if (notFound) Text("Not found", style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                    }
                    Box(Modifier.semantics { contentDescription = "Previous match" }) {
                        ShellPillButton(onClick = { find(forward = false) }, enabled = phase == Phase.LOADED) {
                            Icon(Icons.Filled.KeyboardArrowUp, null, modifier = Modifier.size(16.dp))
                        }
                    }
                    Box(Modifier.semantics { contentDescription = "Next match" }) {
                        ShellPillButton(onClick = { find(forward = true) }, enabled = phase == Phase.LOADED) {
                            Icon(Icons.Filled.KeyboardArrowDown, null, modifier = Modifier.size(16.dp))
                        }
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize().padding(horizontal = 4.dp))
                    when (phase) {
                        Phase.LOADING -> CircularProgressIndicator(Modifier.size(24.dp), color = c.secondary, strokeWidth = 2.dp)
                        Phase.FAILED -> Text("This session's output could not be read.", style = PT.display(15.sp, FontWeight.Normal),
                            color = c.secondary, textAlign = TextAlign.Center, modifier = Modifier.padding(24.dp))
                        Phase.LOADED -> Unit
                    }
                }
            }
        }
    }
}
