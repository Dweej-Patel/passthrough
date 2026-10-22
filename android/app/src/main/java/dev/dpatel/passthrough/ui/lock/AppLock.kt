package dev.dpatel.passthrough.ui.lock

import android.os.SystemClock
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Gate state for the whole app UI. Locks the UI only; the foreground service keeps serving.
 * Starts locked, relocks once the app has been in the background for [RELOCK_AFTER_MS].
 */
class AppLock(private val clock: () -> Long = SystemClock::elapsedRealtime) {
    private val _unlocked = MutableStateFlow(false)
    val unlocked: StateFlow<Boolean> = _unlocked.asStateFlow()

    private var backgroundedAt: Long? = null
    /** True on cold start and after each trip to the background or relock; consumed once per prompt. */
    private var autoPromptPending = true

    /** True while an authenticator is showing. Lives here so it survives activity recreation. */
    var promptInFlight = false
        private set

    /** Claims the single prompt slot; false if one is already showing. */
    fun beginPrompt(): Boolean {
        if (promptInFlight) return false
        promptInFlight = true
        return true
    }

    fun endPrompt() { promptInFlight = false }

    fun onUnlocked() {
        promptInFlight = false
        backgroundedAt = null
        _unlocked.value = true
    }

    /** Idempotent: a second call while already backgrounded keeps the first timestamp. */
    fun onBackground(changingConfigurations: Boolean = false) {
        // Rotation is not a trip to the background.
        if (changingConfigurations) return
        if (backgroundedAt == null) backgroundedAt = clock()
        // The authenticator itself can stop the activity (API < 29 credential screen); that
        // must not re-arm the auto-prompt or cancelling it would loop.
        if (!promptInFlight) autoPromptPending = true
    }

    /** Decides expiry. Call as the activity starts, before content can be drawn. */
    fun onForeground() {
        val since = backgroundedAt ?: return
        backgroundedAt = null
        val away = clock() - since
        // A negative interval means the clock moved; treat that as expired.
        if (away >= RELOCK_AFTER_MS || away < 0) lock()
    }

    /** True once per foregrounding; the gate uses it so cancelling the prompt doesn't loop. */
    fun takeAutoPrompt(): Boolean {
        val pending = autoPromptPending
        autoPromptPending = false
        return pending
    }

    /**
     * Locks now, as if the app had been away too long; the gate prompts at once.
     * Remote shell uses it once when a key needs a fresh unlock (Keystore's 60 s window).
     */
    fun relock() = lock()

    private fun lock() {
        if (!_unlocked.value) return
        _unlocked.value = false
        autoPromptPending = true
    }

    companion object { const val RELOCK_AFTER_MS = 60_000L }
}

/** Keeps the lock across configuration changes (rotation must not relock). */
class LockModel : ViewModel() {
    val lock = AppLock()
}
