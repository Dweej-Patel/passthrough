package dev.dpatel.passthrough.ui.lock

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.service.Runtime
import java.util.WeakHashMap

/**
 * FLAG_SECURE, shared by everything that wants it on a window: the flag goes
 * only when the last holder lets go, so the shell screens and the app-wide
 * Recents cover (before Android 13) can't clear each other's. Main thread only.
 */
internal object SecureFlag {
    private val holders = WeakHashMap<Window, Int>()

    fun acquire(window: Window) {
        val count = (holders[window] ?: 0) + 1
        holders[window] = count
        if (count == 1) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    fun release(window: Window) {
        val count = (holders[window] ?: return) - 1
        if (count > 0) {
            holders[window] = count
        } else {
            holders.remove(window)
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}

/**
 * "Hide shell and Screen from screenshots and recordings": while the calling
 * screen (the terminal, shell history, a session's transcript) shows, the
 * window is kept out of screenshots, screen recordings, casting and Recents,
 * unless the user turned that off in Settings.
 */
@Composable
fun HideFromCapture() {
    val enabled by Runtime.settings.captureProtection.collectAsStateWithLifecycle()
    val view = LocalView.current
    DisposableEffect(view, enabled) {
        val window = if (enabled) view.context.findActivity()?.window else null
        window?.let(SecureFlag::acquire)
        onDispose { window?.let(SecureFlag::release) }
    }
}

internal tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
