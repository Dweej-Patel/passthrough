package dev.dpatel.passthrough.ui.mac

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.GppMaybe
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.BatterySample
import dev.dpatel.passthrough.core.MacEvent
import dev.dpatel.passthrough.core.MacFormat
import dev.dpatel.passthrough.core.MacTimeline
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.tabInsets
import dev.dpatel.passthrough.ui.shell.ShellReach
import dev.dpatel.passthrough.ui.shell.ShellViewModel
import java.text.DateFormat
import java.util.Date

/**
 * What happened on the Mac in the last 24 hours: a summary, the battery
 * meanwhile, then each event.
 */
@Composable
fun ActivityScreen(shell: ShellViewModel, onOpenTerminal: (String) -> Unit, onHistory: () -> Unit) {
    val c = LocalPT.current
    val reach by shell.reach.collectAsStateWithLifecycle()
    val timeline by shell.timeline.collectAsStateWithLifecycle()
    val unsupported by shell.timelineUnsupported.collectAsStateWithLifecycle()
    val sessions by shell.sessions.collectAsStateWithLifecycle()
    val state by shell.macState.collectAsStateWithLifecycle()
    val since = System.currentTimeMillis() / 1000.0 - 86_400
    LaunchedEffect(reach) { if (reach == ShellReach.READY) shell.loadTimeline(since) }

    Column(
        Modifier
            .windowInsetsPadding(tabInsets())
            .verticalScroll(rememberScrollState())
            .fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp)
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Activity", style = PT.display(30.sp), color = c.primary, modifier = Modifier.padding(top = 6.dp))
        val t = timeline
        when {
            unsupported -> Notice("Update Passthrough on your Mac to see what happened on it.")
            t != null -> {
                Summary(t)
                if (t.battery.size > 1) BatteryChart(t.battery, state?.batteryFloor)
                if (reach != ShellReach.READY) Text("As of ${time(t.loadedAt)}. Your Mac can't be reached right now.",
                    style = PT.display(13.sp, FontWeight.Normal), color = c.secondary)
                if (t.events.isEmpty()) Notice("Nothing happened on your Mac in this time.")
                else PTCard(padding = 6.dp) {
                    val newestFirst = t.events.reversed()
                    newestFirst.forEachIndexed { i, e ->
                        val open: (() -> Unit)? = e.session?.let { id ->
                            if (sessions.any { it.id == id && it.running }) ({ onOpenTerminal(id) }) else onHistory
                        }
                        EventRow(e, open)
                        if (i < newestFirst.size - 1) HorizontalDivider(Modifier.padding(start = 56.dp), color = c.cardBorder)
                    }
                }
            }
            reach == ShellReach.READY -> Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = c.tint) }
            else -> Notice("Your Mac's timeline shows up here once this phone can reach it.")
        }
    }
}

@Composable
private fun Notice(text: String) {
    PTCard { Text(text, style = PT.display(14.sp, FontWeight.Normal), color = LocalPT.current.secondary) }
}

private fun time(seconds: Double): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date((seconds * 1000).toLong()))

@Composable
private fun Summary(t: MacTimeline) {
    val c = LocalPT.current
    val answered = t.events.count { it.kind == MacEvent.KIND_ANSWERED }
    val drops = t.events.count { it.warning == true && (it.kind == MacEvent.KIND_VPN || it.kind == MacEvent.KIND_LINK) }
    val finished = t.events.count { it.kind == MacEvent.KIND_SHELL }
    PTCard {
        Text("The last 24 hours", style = PT.display(17.sp), color = c.primary)
        Text(if (t.events.size == 1) "1 event" else "${t.events.size} events",
            style = PT.display(14.sp, FontWeight.Normal), color = c.secondary)
        Row(Modifier.fillMaxWidth().padding(top = 12.dp)) {
            Stat("$finished", if (finished == 1) "shell finished" else "shells finished", Modifier.weight(1f))
            Stat("$answered", "answered", Modifier.weight(1f))
            Stat("$drops", if (drops == 1) "connection drop" else "connection drops", Modifier.weight(1f), warning = drops > 0)
        }
    }
}

@Composable
private fun Stat(value: String, label: String, modifier: Modifier, warning: Boolean = false) {
    val c = LocalPT.current
    Column(modifier.semantics(mergeDescendants = true) {}) {
        Text(value, style = PT.mono(24.sp, FontWeight.Bold), color = if (warning) c.attentionText else c.primary)
        Text(label, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
    }
}

/** One mint line, Keep awake's limit dashed, and the level under your finger. */
@Composable
private fun BatteryChart(samples: List<BatterySample>, floor: Double?) {
    val c = LocalPT.current
    var picked by remember { mutableStateOf<BatterySample?>(null) }
    val first = samples.first().t
    val span = (samples.last().t - first).coerceAtLeast(1.0)
    PTCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Battery", style = PT.display(17.sp), color = c.primary, modifier = Modifier.weight(1f))
            Text(
                picked?.let { "${MacFormat.percent(it.level)} at ${time(it.t)}" } ?: floor?.let { "Keep awake stops at ${MacFormat.percent(it)}" } ?: "",
                style = PT.mono(13.sp, FontWeight.Normal), color = c.secondary,
            )
        }
        val low = samples.minOf { it.level }
        Canvas(
            Modifier.fillMaxWidth().height(120.dp).padding(top = 10.dp)
                .semantics { contentDescription = "Battery over time, from ${MacFormat.percent(samples.first().level)} to ${MacFormat.percent(samples.last().level)}, lowest ${MacFormat.percent(low)}." }
                .pointerInput(samples) {
                    fun pick(x: Float) {
                        val at = first + span * (x / size.width).coerceIn(0f, 1f)
                        picked = samples.minByOrNull { kotlin.math.abs(it.t - at) }
                    }
                    detectDragGestures(onDragStart = { pick(it.x) }, onDragEnd = { picked = null }, onDragCancel = { picked = null }) { change, _ -> pick(change.position.x) }
                },
        ) {
            fun x(t: Double) = ((t - first) / span * size.width).toFloat()
            fun y(level: Double) = (size.height * (1 - level)).toFloat()
            for (g in listOf(0.0, 0.5, 1.0)) drawLine(c.fill, Offset(0f, y(g)), Offset(size.width, y(g)), 1.dp.toPx())
            floor?.let {
                drawLine(c.secondary, Offset(0f, y(it)), Offset(size.width, y(it)), 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())))
            }
            val path = Path().apply {
                samples.forEachIndexed { i, s -> if (i == 0) moveTo(x(s.t), y(s.level)) else lineTo(x(s.t), y(s.level)) }
            }
            drawPath(path, c.tint, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            picked?.let {
                drawLine(c.secondary.copy(alpha = 0.4f), Offset(x(it.t), 0f), Offset(x(it.t), size.height), 1.dp.toPx())
                drawCircle(c.card, 6.dp.toPx(), Offset(x(it.t), y(it.level)))
                drawCircle(c.tint, 4.dp.toPx(), Offset(x(it.t), y(it.level)))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
            Text(time(samples.first().t), style = PT.display(11.sp, FontWeight.Normal), color = c.secondary, modifier = Modifier.weight(1f))
            Text(time(samples.last().t), style = PT.display(11.sp, FontWeight.Normal), color = c.secondary)
        }
    }
}

@Composable
private fun EventRow(event: MacEvent, open: (() -> Unit)?) {
    val c = LocalPT.current
    val warning = event.warning == true
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp)
            .then(if (open != null) Modifier.clickable(role = Role.Button, onClick = open) else Modifier)
            .padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(30.dp).background(if (warning) PT.attention else c.tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon(event), null, tint = if (warning) PT.onAttention else c.tintText, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(time(event.t), style = PT.mono(12.sp, FontWeight.Normal), color = c.secondary)
            Text(event.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary)
            event.detail?.let {
                if (event.kind == MacEvent.KIND_ASKED) Text(it, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = c.secondary)
                else Text(it, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
            }
        }
        if (open != null) Icon(Icons.Filled.ChevronRight, null, tint = c.tertiary, modifier = Modifier.padding(top = 18.dp))
    }
}

private fun icon(e: MacEvent): ImageVector = when (e.kind) {
    MacEvent.KIND_AWAKE -> Icons.Filled.Coffee
    MacEvent.KIND_VPN -> if (e.warning == true) Icons.Filled.GppMaybe else Icons.Filled.Shield
    MacEvent.KIND_LINK -> Icons.Filled.Cable
    MacEvent.KIND_POWER -> Icons.Filled.Bolt
    MacEvent.KIND_SLEEP -> Icons.Filled.Bedtime
    MacEvent.KIND_SHELL -> if (e.warning == true) Icons.Filled.Close else Icons.Filled.Check
    MacEvent.KIND_ASKED -> Icons.Filled.QuestionMark
    MacEvent.KIND_ANSWERED -> Icons.AutoMirrored.Filled.Reply
    else -> Icons.Filled.Circle
}
