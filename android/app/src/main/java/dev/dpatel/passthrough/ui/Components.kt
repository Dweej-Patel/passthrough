package dev.dpatel.passthrough.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.PowerSettingsNew
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dpatel.passthrough.core.ByteFormat
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ThroughputSample
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun PTSectionTitle(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    val c = LocalPT.current
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (icon != null) Icon(icon, null, tint = c.secondary, modifier = Modifier.size(13.dp))
        Text(text.uppercase(), style = PT.display(12.sp, FontWeight.SemiBold).copy(letterSpacing = 1.1.sp), color = c.secondary)
    }
}

/** Small capsule chip, e.g. "5G", "USB". */
@Composable
fun PTPill(text: String, icon: ImageVector? = null, tint: Color = LocalPT.current.secondary) {
    Row(
        Modifier.background(tint.copy(alpha = 0.14f), CircleShape).padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = tint, modifier = Modifier.size(12.dp))
        Text(text, style = PT.display(12.sp, FontWeight.SemiBold), color = tint)
    }
}

/** Status dot with a soft halo, pulsing when live. */
@Composable
fun PTStatusDot(color: Color, live: Boolean) {
    val t = rememberInfiniteTransition(label = "dot")
    val p by t.animateFloat(0f, 1f, infiniteRepeatable(tween(1400, easing = FastOutSlowInEasing), RepeatMode.Restart), label = "pulse")
    Canvas(Modifier.size(16.dp)) {
        val scale = if (live) 1f + 0.5f * p else 1f
        val haloAlpha = if (live) 0.35f * (1f - p) else 0.35f
        drawCircle(color.copy(alpha = haloAlpha), radius = 8.dp.toPx() * scale)
        drawCircle(color, radius = 4.dp.toPx())
    }
}

enum class RingMode { IDLE, BUSY, LIVE, ERROR }

/** Animated ring that idles grey, spins while connecting, and glows when live. */
@Composable
fun StatusRing(mode: RingMode, size: Dp = 196.dp, lineWidth: Dp = 11.dp) {
    val c = LocalPT.current
    val t = rememberInfiniteTransition(label = "ring")
    val busySpin by t.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "busy")
    val liveSpin by t.animateFloat(0f, 360f, infiniteRepeatable(tween(6000, easing = LinearEasing)), label = "live")
    val breathe by t.animateFloat(0f, 1f, infiniteRepeatable(tween(2200, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "breathe")
    val sweep = Brush.sweepGradient(listOf(PT.accentStart, PT.accentEnd, PT.accentStart))
    Canvas(Modifier.size(size)) {
        val w = lineWidth.toPx()
        val inset = w / 2
        val arcSize = androidx.compose.ui.geometry.Size(this.size.width - w, this.size.height - w)
        val topLeft = Offset(inset, inset)
        drawCircle(c.primary.copy(alpha = 0.08f), radius = this.size.minDimension / 2 - inset, style = Stroke(w))
        when (mode) {
            RingMode.IDLE -> {}
            RingMode.BUSY -> rotate(busySpin) {
                drawArc(sweep, 0f, 0.28f * 360f, false, topLeft, arcSize, style = Stroke(w, cap = StrokeCap.Round))
            }
            RingMode.LIVE -> rotate(liveSpin) {
                // Soft glow under the ring, breathing like the iOS shadow.
                val glowAlpha = 0.10f + 0.12f * breathe
                for (k in 1..3) {
                    drawCircle(PT.accentStart.copy(alpha = glowAlpha / k), radius = this.size.minDimension / 2 - inset, style = Stroke(w + (6 + 8 * breathe) * k))
                }
                drawCircle(sweep, radius = this.size.minDimension / 2 - inset, style = Stroke(w, cap = StrokeCap.Round))
            }
            RingMode.ERROR -> drawCircle(PT.danger.copy(alpha = 0.8f), radius = this.size.minDimension / 2 - inset, style = Stroke(w))
        }
    }
}

@Composable
fun PowerButton(isOn: Boolean, busy: Boolean, onClick: () -> Unit) {
    val c = LocalPT.current
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (pressed) 0.94f else 1f, tween(150), label = "press")
    val haptics = LocalHapticFeedback.current
    Box(
        Modifier
            .size(128.dp)
            .scale(scale)
            .clip(CircleShape)
            .background(if (isOn) c.tint else c.fill)
            .semantics { contentDescription = if (isOn) "Stop passthrough" else "Start passthrough" }
            .pointerInput(busy) {
                detectTapGestures(
                    onPress = { pressed = true; tryAwaitRelease(); pressed = false },
                    onTap = { if (!busy) { haptics.performHapticFeedback(HapticFeedbackType.LongPress); onClick() } },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.PowerSettingsNew, null,
            tint = if (isOn) PT.onTint else c.primary.copy(alpha = 0.6f),
            modifier = Modifier.size(52.dp).alpha(if (busy) 0.4f else 1f),
        )
    }
}

/** Large throughput number with a unit and direction glyph. */
@Composable
fun RateReadout(bytesPerSecond: Double, down: Boolean, size: Int = 30) {
    val (value, unit) = ByteFormat.rate(bytesPerSecond)
    val c = LocalPT.current
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.semantics { contentDescription = "${if (down) "Download" else "Upload"} $value $unit" }) {
        Icon(if (down) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward, null,
            tint = if (down) PT.down else PT.up, modifier = Modifier.size((size * 0.62).dp).padding(bottom = (size * 0.12).dp))
        Text(value, style = PT.mono(size.sp, FontWeight.Bold), color = c.primary)
        Text(unit, style = PT.display((size * 0.42).sp, FontWeight.SemiBold), color = c.secondary, modifier = Modifier.padding(bottom = (size * 0.08).dp))
    }
}

/** Label + value pair used in stat rows. */
@Composable
fun StatCell(title: String, value: String, tint: Color? = null, modifier: Modifier = Modifier) {
    val c = LocalPT.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(title, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
        Text(value, style = PT.mono(17.sp, FontWeight.SemiBold), color = tint ?: c.primary)
    }
}

/** Six digit pairing code rendered as large tiles. */
@Composable
fun PairingCodeTiles(code: String, size: Dp = 50.dp) {
    val c = LocalPT.current
    val shape = RoundedCornerShape(size * 0.22f)
    Row(horizontalArrangement = Arrangement.spacedBy(size * 0.16f), verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics { contentDescription = "Pairing code ${code.toList().joinToString(" ")}" }) {
        code.forEachIndexed { index, ch ->
            Box(
                Modifier.width(size).height(size * 1.25f).background(c.thinFill, shape).border(1.5.dp, PT.accent, shape).alpha(1f),
                contentAlignment = Alignment.Center,
            ) {
                Text(ch.toString(), style = PT.mono((size.value * 0.62f).sp, FontWeight.Bold), color = c.primary)
            }
            if (index == 2) Spacer(Modifier.width(size * 0.2f))
        }
    }
}

/** Download/upload split of this month's usage. */
@Composable
fun UsageBar(down: Double, up: Double) {
    val total = maxOf(down + up, 1.0)
    Canvas(Modifier.fillMaxWidth().height(6.dp).semantics { contentDescription = "Download ${ByteFormat.bytes(down.toLong())}, upload ${ByteFormat.bytes(up.toLong())}" }) {
        val gap = 2.dp.toPx()
        val minW = 4.dp.toPx()
        val avail = size.width - gap
        val dw = maxOf(minW, (avail * down / total).toFloat())
        val uw = maxOf(minW, avail - dw)
        val r = androidx.compose.ui.geometry.CornerRadius(size.height / 2)
        drawRoundRect(PT.down, Offset.Zero, androidx.compose.ui.geometry.Size(dw, size.height), r)
        drawRoundRect(PT.up, Offset(dw + gap, 0f), androidx.compose.ui.geometry.Size(uw, size.height), r)
    }
}

/**
 * Sixty seconds of throughput: teal area for download, violet for upload.
 * Smoothed with Catmull-Rom curves; the peak value is the only label.
 */
@Composable
fun ThroughputChart(samples: List<ThroughputSample>, height: Dp = 110.dp, window: Int = 60, idleLabel: String? = null) {
    val c = LocalPT.current
    val peak = maxOf(samples.maxOfOrNull { maxOf(it.down, it.up) } ?: 0.0, 1024.0)
    val hasTraffic = samples.any { it.down > 0 || it.up > 0 }
    Box(Modifier.fillMaxWidth().height(height).semantics { contentDescription = "Throughput over the last minute" }) {
        Canvas(Modifier.matchParentSize()) {
            val scale = peak * 1.15
            fun draw(values: List<Double>, color: Color, fillTop: Float, lineWidth: Float) {
                if (values.size < 2) return
                val n = values.size
                val stepX = size.width / (window - 1).coerceAtLeast(1)
                val startX = size.width - stepX * (n - 1)
                val inset = lineWidth
                fun pt(i: Int) = Offset(startX + stepX * i, size.height - inset - (minOf(1.0, values[i] / scale)).toFloat() * (size.height - 2 * inset))
                val line = Path().apply {
                    moveTo(pt(0).x, pt(0).y)
                    for (i in 0 until n - 1) {
                        val p0 = pt(maxOf(0, i - 1)); val p1 = pt(i); val p2 = pt(i + 1); val p3 = pt(minOf(n - 1, i + 2))
                        cubicTo(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6, p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6, p2.x, p2.y)
                    }
                }
                val area = Path().apply {
                    addPath(line)
                    lineTo(pt(n - 1).x, size.height)
                    lineTo(pt(0).x, size.height)
                    close()
                }
                drawPath(area, Brush.verticalGradient(listOf(color.copy(alpha = fillTop), color.copy(alpha = 0.02f)), 0f, size.height))
                drawPath(line, color, style = Stroke(lineWidth, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            draw(samples.map { it.down }, PT.down, 0.45f, 2.dp.toPx())
            draw(samples.map { it.up }, PT.up, 0.35f, 1.5.dp.toPx())
        }
        if (!hasTraffic && idleLabel != null) {
            Text(idleLabel, style = PT.display(13.sp, FontWeight.Normal), color = c.tertiary, textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center).padding(horizontal = 16.dp))
        }
        if (hasTraffic) {
            val (v, u) = ByteFormat.rate(peak)
            Text("$v $u", style = PT.display(11.sp, FontWeight.Normal), color = c.tertiary, modifier = Modifier.align(Alignment.TopEnd).padding(end = 2.dp))
        }
    }
}

/** Diagnostics log list. */
@Composable
fun LogList(entries: List<PtLog.Entry>, showDebug: Boolean, modifier: Modifier = Modifier) {
    val c = LocalPT.current
    val shown = if (showDebug) entries else entries.filter { it.level != PtLog.Level.DEBUG }
    val state = rememberLazyListState()
    LaunchedEffect(shown.size) { if (shown.isNotEmpty()) state.scrollToItem(shown.size - 1) }
    val fmt = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }
    SelectionContainer {
        LazyColumn(modifier.background(c.primary.copy(alpha = 0.04f), RoundedCornerShape(12.dp)).padding(10.dp), state = state,
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(shown) { e ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(fmt.format(Date(e.date)), fontFamily = FontFamily.Monospace, fontSize = 10.sp, color = c.tertiary)
                    Text(e.message, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = when (e.level) {
                        PtLog.Level.DEBUG -> c.secondary
                        PtLog.Level.INFO -> c.primary
                        PtLog.Level.WARNING -> PT.warning
                        PtLog.Level.ERROR -> PT.danger
                    })
                }
            }
        }
    }
}

/**
 * A screen's top bar: centred title and a trailing Done (or a leading back
 * action), each with a 48 dp touch target.
 */
@Composable
fun PTTopBar(title: String, onDone: (() -> Unit)? = null, doneLabel: String = "Done", onBack: (() -> Unit)? = null, backLabel: String = "Back") {
    val c = LocalPT.current
    Box(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
        Text(
            title, style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 96.dp).semantics { heading() },
        )
        if (onBack != null) {
            Row(
                Modifier.align(Alignment.CenterStart).heightIn(min = 48.dp).clip(CircleShape).clickable(onClick = onBack).padding(end = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null, tint = PT.accentEnd, modifier = Modifier.size(28.dp))
                Text(backLabel, style = PT.display(17.sp, FontWeight.Normal), color = PT.accentEnd, maxLines = 1)
            }
        }
        if (onDone != null) {
            Box(
                Modifier.align(Alignment.CenterEnd).heightIn(min = 48.dp).widthIn(min = 48.dp).clip(CircleShape).clickable(onClick = onDone)
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(doneLabel, style = PT.display(17.sp, FontWeight.Bold), color = PT.accentEnd, maxLines = 1)
            }
        }
    }
}

/** A round icon button on a card-coloured disc, with a 48 dp touch target. */
@Composable
fun PTCircleIconButton(icon: ImageVector, description: String, onClick: () -> Unit, size: Dp = 44.dp, iconSize: Dp = 22.dp) {
    val c = LocalPT.current
    Box(
        Modifier
            .size(maxOf(size, 48.dp))
            .clip(CircleShape)
            .clickable(onClick = onClick, role = Role.Button)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(size).background(c.card, CircleShape).border(1.dp, c.cardBorder, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = c.secondary, modifier = Modifier.size(iconSize))
        }
    }
}

/** Numbered setup steps, so what to do next is obvious. */
@Composable
fun PTSteps(steps: List<String>, modifier: Modifier = Modifier) {
    val c = LocalPT.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        steps.forEachIndexed { i, step ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.size(22.dp).background(PT.accentEnd.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                    Text("${i + 1}", style = PT.mono(12.sp, FontWeight.Bold), color = PT.accentEnd)
                }
                Text(step, style = PT.display(15.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f).padding(top = 1.dp))
            }
        }
    }
}

/**
 * A tinted note inside a card: an icon, a title, optional detail and an
 * optional action (e.g. the warning when USB debugging is off).
 */
@Composable
fun PTNotice(
    title: String,
    tint: Color,
    icon: ImageVector,
    detail: String? = null,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val c = LocalPT.current
    // Amber and friends are too light to read on the light theme's pale cards: deepen them there.
    val ink = if (c.dark) tint else lerp(tint, Color.Black, 0.38f)
    Column(
        Modifier.fillMaxWidth().background(tint.copy(alpha = if (c.dark) 0.12f else 0.16f), RoundedCornerShape(14.dp)).padding(start = 12.dp, end = 12.dp, top = 12.dp,
            bottom = if (action != null) 2.dp else 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            Icon(icon, null, tint = ink, modifier = Modifier.padding(top = 1.dp).size(18.dp))
            Text(title, style = PT.display(15.sp, FontWeight.SemiBold), color = ink, modifier = Modifier.weight(1f))
        }
        if (detail != null) Text(detail, style = PT.display(13.sp, FontWeight.Normal), color = c.secondary)
        if (action != null && onAction != null) {
            Text(
                action, style = PT.display(14.sp, FontWeight.Bold), color = ink,
                modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).clickable(onClick = onAction, role = Role.Button)
                    .padding(vertical = 14.dp),
            )
        }
    }
}
