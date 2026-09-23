package dev.dpatel.passthrough.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

data class FlowMapState(
    val macName: String = "Mac",
    val phoneName: String = "Phone",
    /** A Mac is being served over USB. */
    val linkUp: Boolean = false,
    /** Starting, or running with no Mac yet. */
    val busy: Boolean = false,
    val radio: String? = null,
    val downRate: Double = 0.0,
    val upRate: Double = 0.0,
    val activeConnections: Int = 0,
)

/** Integrates particle travel over time with smoothed speeds so rate changes never make streaks jump. */
private class FlowClock {
    private var last = 0L
    private var speedDown = 0.0
    private var speedUp = 0.0
    var travelDown = 0.0; private set
    var travelUp = 0.0; private set

    fun advance(nowNanos: Long, down: Double, up: Double, pxPerPt: Float) {
        val dt = if (last == 0L) 0.0 else min(0.1, max(0.0, (nowNanos - last) / 1e9))
        last = nowNanos
        val k = 1 - exp(-dt * 4)
        speedDown += (pixelsPerSecond(down) * pxPerPt - speedDown) * k
        speedUp += (pixelsPerSecond(up) * pxPerPt - speedUp) * k
        travelDown += speedDown * dt
        travelUp += speedUp * dt
    }

    companion object {
        /** 2 KB/s ≈ crawl, 30 MB/s ≈ full speed; log-scaled so both ends stay readable. */
        fun norm(rate: Double): Double =
            if (rate <= 0) 0.0 else min(1.0, max(0.0, log10(1 + rate / 2000) / log10(1 + 30_000_000.0 / 2000)))
        fun pixelsPerSecond(rate: Double) = if (rate <= 0) 0.0 else 36 + 260 * norm(rate)
    }
}

/**
 * Animated picture of the path traffic takes: Mac ⟶ USB ⟶ phone ⟶ radio ⟶ Internet.
 * Streaks ride two lanes per hop (teal toward the Mac for download, violet away
 * for upload) at a speed and density that follow live throughput. Ticks at
 * ≤24 fps and only while something moves and the screen is showing.
 */
@Composable
fun FlowMap(state: FlowMapState, height: Dp = 90.dp, active: Boolean = true) {
    val c = LocalPT.current
    val density = LocalDensity.current
    val clock = remember { FlowClock() }
    val linkProgress by animateFloatAsState(if (state.linkUp) 1f else 0f, tween(550), label = "link")
    val moving = active && (state.linkUp || state.busy)
    val fast = state.downRate + state.upRate > 0 || state.busy
    var frameNanos by remember { mutableLongStateOf(0L) }
    LaunchedEffect(moving, fast) {
        while (moving) {
            frameNanos = System.nanoTime()
            delay(if (fast) 42 else 83)
        }
    }
    val description = buildString {
        append(if (state.linkUp) "Traffic flows from ${state.macName} over USB to ${state.phoneName}" else "No traffic; USB link down")
        state.radio?.let { append(", then over $it") }
    }

    BoxWithConstraints(Modifier.fillMaxWidth().height(height).semantics { contentDescription = description }) {
        val widthDp = maxWidth
        val margin = 40.dp
        val nodeR = 22.dp
        val nodeY = 30.dp
        val xs = listOf(margin, margin + (widthDp - margin * 2) / 2, widthDp - margin)

        Canvas(Modifier.fillMaxSize()) {
            val t = frameNanos / 1e9
            clock.advance(frameNanos, state.downRate, state.upRate, density.density)
            drawWires(state, c, xs.map { it.toPx() }, nodeR.toPx(), nodeY.toPx(), linkProgress, clock, t)
        }

        val activeTint = PT.accentStart
        FlowNode(Icons.Filled.LaptopMac, state.macName, if (state.linkUp) activeTint else c.secondary, dim = !state.linkUp, x = xs[0], y = nodeY, r = nodeR)
        FlowNode(Icons.Filled.PhoneAndroid, state.phoneName, activeTint, dim = false, x = xs[1], y = nodeY, r = nodeR)
        FlowNode(Icons.Filled.Public, "Internet", c.secondary, dim = !state.linkUp, x = xs[2], y = nodeY, r = nodeR)
        WireLabel("USB", x = (xs[0] + xs[1]) / 2, y = nodeY + 7.dp)
        WireLabel(state.radio ?: "cellular", x = (xs[1] + xs[2]) / 2, y = nodeY + 7.dp)
    }
}

private fun DrawScope.drawWires(
    state: FlowMapState, c: PTColors, xs: List<Float>, r: Float, y: Float, linkProgress: Float, clock: FlowClock, t: Double,
) {
    val lane = 3.5f * density
    val gap = 4 * density
    val segments = listOf(xs[0] + r + gap to xs[1] - r - gap, xs[1] + r + gap to xs[2] - r - gap)
    val neutral = c.primary.copy(alpha = if (c.dark) 0.16f else 0.12f)
    val linkAlpha = 0.25f + 0.75f * linkProgress
    for ((from, to) in segments) {
        if (state.linkUp || linkProgress > 0.01f) {
            val tint = (if (c.dark) 0.30f else 0.38f) * linkAlpha
            drawLine(PT.down.copy(alpha = tint), Offset(from, y - lane), Offset(to, y - lane), 2 * density, StrokeCap.Round)
            drawLine(PT.up.copy(alpha = tint), Offset(from, y + lane), Offset(to, y + lane), 2 * density, StrokeCap.Round)
        } else {
            drawLine(neutral, Offset(from, y), Offset(to, y), 1.5f * density, StrokeCap.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(3 * density, 6 * density)))
        }
    }
    if (state.linkUp) {
        val span = segments.first().first to segments.last().second
        val gaps = listOf((xs[1] - r)..(xs[1] + r))
        drawStream(span, gaps, y - lane, state.downRate, clock.travelDown, towardMac = true, color = PT.down, t = t)
        drawStream(span, gaps, y + lane, state.upRate, clock.travelUp, towardMac = false, color = PT.up, t = t)
    } else if (state.busy) {
        val (from, to) = segments[0]
        val len = to - from
        val phase = ((t * 0.7) % 1.0).toFloat()
        val head = from + len * phase
        streak(head, max(from, head - 18 * density), y, PT.accentStart, 0.7f)
    }
}

private fun DrawScope.drawStream(
    span: Pair<Float, Float>, gaps: List<ClosedFloatingPointRange<Float>>, y: Float, rate: Double, travel: Double,
    towardMac: Boolean, color: Color, t: Double,
) {
    val len = (span.second - span.first).toDouble()
    if (len <= 10) return
    val norm = FlowClock.norm(rate)
    val n = if (rate > 0) 1 + (4 * norm).toInt() else 1
    val spacing = len / n
    val streakLen = (if (rate > 0) 14 + 22 * norm else 12.0).toFloat() * density
    val alpha = if (rate > 0) (0.55 + 0.35 * norm).toFloat() else 0.22f
    for (i in 0 until n) {
        var d = (travel + i * spacing + (if (rate > 0) 0.0 else t * 14 * density)) % len
        if (d < 0) d += len
        val head = if (towardMac) span.second - d.toFloat() else span.first + d.toFloat()
        if (gaps.any { head in it }) continue
        val tail = if (towardMac) min(span.second, head + streakLen) else max(span.first, head - streakLen)
        streak(head, tail, y, color, alpha)
    }
}

private fun DrawScope.streak(head: Float, tail: Float, y: Float, color: Color, alpha: Float) {
    if (head == tail) return
    drawLine(
        Brush.linearGradient(listOf(color.copy(alpha = 0f), color.copy(alpha = alpha)), Offset(tail, y), Offset(head, y)),
        Offset(tail, y), Offset(head, y), 2.5f * density, StrokeCap.Round,
    )
}

@Composable
private fun FlowNode(icon: ImageVector, label: String, tint: Color, dim: Boolean, x: Dp, y: Dp, r: Dp) {
    val c = LocalPT.current
    val labelWidth = 72.dp
    Column(
        Modifier.offset(x = x - labelWidth / 2, y = y - r).width(labelWidth).alpha(if (dim) 0.55f else 1f),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(r * 2).background(c.primary.copy(alpha = if (c.dark) 0.10f else 0.06f), CircleShape)
                .border(1.2.dp, tint.copy(alpha = if (dim) 0.2f else 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp)) }
        Text(label, style = PT.display(10.sp, FontWeight.Medium), color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp).fillMaxWidth())
    }
}

@Composable
private fun WireLabel(text: String, x: Dp, y: Dp) {
    val c = LocalPT.current
    val w = 70.dp
    Text(text.uppercase(), style = PT.display(8.sp, FontWeight.SemiBold).copy(letterSpacing = 0.8.sp), color = c.tertiary,
        textAlign = TextAlign.Center, maxLines = 1, modifier = Modifier.offset(x = x - w / 2, y = y).width(w))
}

