package dev.dpatel.passthrough.ui.lock

import android.os.SystemClock
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Why the app is locked, so the lock screen can say so. */
enum class LockReason {
    /** Cold start. */
    STARTUP,
    /** Back after [AppLock.RELOCK_AFTER_MS] or more in the background. */
    AWAY,
    /** Remote shell received a key that only a fresh unlock can store ([AppLock.relock]). */
    SHELL_KEY,
}

/**
 * Gate state for the whole app UI. Locks the UI only; the foreground service keeps serving.
 * Starts locked, relocks once the app has been in the background for [RELOCK_AFTER_MS].
 *
 * Never asks for authentication by itself: the lock screen shows first and the
 * authenticator starts only when the user taps Unlock.
 */
class AppLock(private val clock: () -> Long = SystemClock::elapsedRealtime) {
    private val _unlocked = MutableStateFlow(false)
    val unlocked: StateFlow<Boolean> = _unlocked.asStateFlow()

    private val _reason = MutableStateFlow(LockReason.STARTUP)
    /** Why the lock last closed; meaningful while locked. */
    val reason: StateFlow<LockReason> = _reason.asStateFlow()

    private var backgroundedAt: Long? = null

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
    }

    /** Decides expiry. Call as the activity starts, before content can be drawn. */
    fun onForeground() {
        val since = backgroundedAt ?: return
        backgroundedAt = null
        val away = clock() - since
        // A negative interval means the clock moved; treat that as expired.
        if (away >= RELOCK_AFTER_MS || away < 0) lock(LockReason.AWAY)
    }

    /**
     * Locks now, as if the app had been away too long. Remote shell uses it once when
     * a key needs a fresh unlock (the shell key vault opens only with the unlock prompt's
     * cipher, or within Keystore's 60 s window on Android 10); the lock screen says why.
     */
    fun relock(reason: LockReason = LockReason.SHELL_KEY) = lock(reason)

    private fun lock(reason: LockReason) {
        if (!_unlocked.value) return
        _reason.value = reason
        _unlocked.value = false
    }

    companion object { const val RELOCK_AFTER_MS = 60_000L }
}

/** Keeps the lock across configuration changes (rotation must not relock). */
class LockModel : ViewModel() {
    val lock = AppLock()
}
