package dev.dpatel.passthrough.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dpatel.passthrough.R

/**
 * The Passthrough visual language, shared with the iOS and Mac apps: deep
 * graphite surfaces, a teal→violet accent, rounded numerals and glass cards.
 */
object PT {
    val down = Color(0xFF40E0D1)      // teal: bytes arriving at the Mac
    val up = Color(0xFFB585FF)        // violet: bytes leaving the Mac
    val accentStart = down
    val accentEnd = up
    val warning = Color(0xFFFFB84D)
    val danger = Color(0xFFFF6B6B)
    val success = Color(0xFF5CE68F)

    val accent: Brush get() = Brush.linearGradient(listOf(accentStart, accentEnd))

    @OptIn(ExperimentalTextApi::class)
    private fun nunito(weight: FontWeight) = Font(
        R.font.nunito, weight = weight,
        variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight)),
    )

    val rounded = FontFamily(
        nunito(FontWeight.Normal), nunito(FontWeight.Medium), nunito(FontWeight.SemiBold),
        nunito(FontWeight.Bold), nunito(FontWeight.ExtraBold),
    )

    fun display(size: TextUnit, weight: FontWeight = FontWeight.Bold) = TextStyle(fontFamily = rounded, fontSize = size, fontWeight = weight)

    /** Rounded with tabular figures, so changing numbers don't jiggle. */
    fun mono(size: TextUnit, weight: FontWeight = FontWeight.Medium) =
        TextStyle(fontFamily = rounded, fontSize = size, fontWeight = weight, fontFeatureSettings = "tnum")
}

/** Label colours matching iOS's primary/secondary/tertiary for the current scheme. */
data class PTColors(val dark: Boolean) {
    val primary = if (dark) Color.White else Color.Black
    val secondary = if (dark) Color(0x99EBEBF5) else Color(0x993C3C43)
    val tertiary = if (dark) Color(0x4DEBEBF5) else Color(0x4D3C3C43)
    val background = if (dark) Color(0xFF0D0F17) else Color(0xFFF2F5FA)
    val card = if (dark) Color(0xB31C1F2B) else Color(0xCCFFFFFF)
    val cardBorder = if (dark) Color.White.copy(alpha = 0.08f) else Color.White.copy(alpha = 0.5f)
    val fill = if (dark) Color.White.copy(alpha = 0.08f) else Color.Black.copy(alpha = 0.06f)
    val thinFill = if (dark) Color.White.copy(alpha = 0.06f) else Color.White.copy(alpha = 0.7f)
}

val LocalPT = staticCompositionLocalOf { PTColors(true) }

@Composable
fun PassthroughTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = PTColors(dark)
    val scheme = if (dark) darkColorScheme(
        primary = PT.accentEnd, secondary = PT.accentStart, background = colors.background, surface = Color(0xFF161925),
        onPrimary = Color.White, onBackground = Color.White, onSurface = Color.White, error = PT.danger,
        surfaceContainerHigh = Color(0xFF1E2130), surfaceContainerLow = Color(0xFF161925),
    ) else lightColorScheme(
        primary = Color(0xFF7B4FE0), secondary = Color(0xFF14A89B), background = colors.background, surface = Color.White,
        onPrimary = Color.White, onBackground = Color.Black, onSurface = Color.Black, error = Color(0xFFD93A3A),
    )
    val base = MaterialTheme.typography
    val typography = base.copy(
        headlineLarge = base.headlineLarge.copy(fontFamily = PT.rounded),
        titleLarge = base.titleLarge.copy(fontFamily = PT.rounded, fontWeight = FontWeight.Bold),
        titleMedium = base.titleMedium.copy(fontFamily = PT.rounded, fontWeight = FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.copy(fontFamily = PT.rounded),
        bodyMedium = base.bodyMedium.copy(fontFamily = PT.rounded),
        bodySmall = base.bodySmall.copy(fontFamily = PT.rounded),
        labelLarge = base.labelLarge.copy(fontFamily = PT.rounded, fontWeight = FontWeight.SemiBold),
        labelMedium = base.labelMedium.copy(fontFamily = PT.rounded),
        labelSmall = base.labelSmall.copy(fontFamily = PT.rounded),
    )
    CompositionLocalProvider(LocalPT provides colors) {
        MaterialTheme(colorScheme = scheme, typography = typography, content = content)
    }
}

/** Near-black graphite (or pale grey) with two soft accent glows. */
@Composable
fun PTBackground(glow: Float, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit = {}) {
    val c = LocalPT.current
    val g by animateFloatAsState(glow, tween(1200), label = "glow")
    Box(
        modifier
            .fillMaxSize()
            .background(c.background)
            .drawBehind {
                val w = size.width
                val h = size.height
                val a1 = (if (c.dark) 0.22f else 0.18f) * g
                val a2 = (if (c.dark) 0.20f else 0.16f) * g
                drawCircle(
                    Brush.radialGradient(listOf(PT.accentStart.copy(alpha = a1), Color.Transparent), center = Offset(w * 0.15f, h * 0.25f), radius = w * 0.85f),
                    radius = w * 0.85f, center = Offset(w * 0.15f, h * 0.25f),
                )
                drawCircle(
                    Brush.radialGradient(listOf(PT.accentEnd.copy(alpha = a2), Color.Transparent), center = Offset(w * 0.95f, h * 0.95f), radius = w * 0.8f),
                    radius = w * 0.8f, center = Offset(w * 0.95f, h * 0.95f),
                )
            },
        content = content,
    )
}

/** Glass card container. */
@Composable
fun PTCard(modifier: Modifier = Modifier, padding: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    val c = LocalPT.current
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .fillMaxWidth()
            .then(if (c.dark) Modifier else Modifier.shadow(14.dp, shape, ambientColor = Color.Black.copy(alpha = 0.08f), spotColor = Color.Black.copy(alpha = 0.08f)))
            .background(c.card, shape)
            .border(1.dp, c.cardBorder, shape)
            .padding(PaddingValues(padding)),
        content = content,
    )
}

