package dev.dpatel.passthrough.ui.lock

import android.app.KeyguardManager
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.repeatOnLifecycle
import dev.dpatel.passthrough.R
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTBackground
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "AppLock"

/**
 * Root gate for the app. [content] is composed only while unlocked, so locked UI never renders
 * and its dialogs, sheets and menus are torn down on relock (returning to Home on unlock).
 * Expiry is decided on ON_START, before the first frame is drawn.
 */
@Composable
fun LockGate(lock: AppLock, activity: FragmentActivity, content: @Composable () -> Unit) {
    // Collected without lifecycle awareness on purpose: a relock decided in onStart must be
    // applied before the first frame, not after the collector restarts.
    val unlocked by lock.unlocked.collectAsState()

    PrivacyWindow(activity)

    DisposableEffect(activity, lock) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> lock.onBackground(activity.isChangingConfigurations)
                Lifecycle.Event.ON_START -> lock.onForeground()
                else -> Unit
            }
        }
        activity.lifecycle.addObserver(observer)
        onDispose { activity.lifecycle.removeObserver(observer) }
    }

    if (unlocked) {
        content()
    } else {
        LockScreen(lock, activity)
    }
}

/**
 * Keeps content out of the Recents thumbnail (and screenshots on API < 33, where only
 * FLAG_SECURE does that). The shell's screens add FLAG_SECURE on every API ([HideFromCapture]).
 */
@Composable
private fun PrivacyWindow(activity: FragmentActivity) {
    DisposableEffect(activity) {
        val window = activity.window
        if (Build.VERSION.SDK_INT >= 33) {
            activity.setRecentsScreenshotEnabled(false)
        } else {
            SecureFlag.acquire(window)
        }
        onDispose {
            if (Build.VERSION.SDK_INT >= 33) activity.setRecentsScreenshotEnabled(true)
            else SecureFlag.release(window)
        }
    }
}

/**
 * The branded lock screen. It never starts the authenticator by itself: the
 * prompt appears only when the user taps Unlock. A device with no secure lock
 * screen has nothing to check, so it passes straight through.
 */
@Composable
private fun LockScreen(lock: AppLock, activity: FragmentActivity) {
    var error by remember { mutableStateOf<String?>(null) }
    val reason by lock.reason.collectAsState()
    var method by remember { mutableStateOf(unlockMethod(activity)) }
    val scope = rememberCoroutineScope()

    val prompt = remember(activity) {
        BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    error = null
                    // This prompt also opened the shell key vault (Android 11+): hand it the authorized cipher.
                    result.cryptoObject?.cipher?.let(Runtime.shellVault::authorize)
                    lock.onUnlocked()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    lock.endPrompt()
                    when (errorCode) {
                        BiometricPrompt.ERROR_USER_CANCELED,
                        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                        BiometricPrompt.ERROR_CANCELED -> Log.i(TAG, "Unlock not completed ($errorCode)")
                        else -> {
                            Log.w(TAG, "Unlock error $errorCode: $errString")
                            error = errString.toString().ifBlank { "Couldn't unlock. Try again." }
                        }
                    }
                }
                // onAuthenticationFailed (a non-matching finger) keeps the prompt open: nothing to do.
            },
        )
    }

    fun unlock() {
        if (!hasSecureLock(activity)) {
            // No secure lock screen: there is nothing to check, so don't strand the user.
            Log.i(TAG, "No device lock screen set; unlocking without authentication")
            lock.onUnlocked()
            return
        }
        if (!lock.beginPrompt()) return
        error = null
        scope.launch {
            // The shell key vault's cipher, when it has keys to open or store: this one
            // prompt authorizes it, so several Macs never mean several prompts.
            val cipher = try {
                withContext(Dispatchers.IO) { runCatching { Runtime.shellVault.unlockCipher(Runtime.registry) }.getOrNull() }
            } catch (e: CancellationException) {
                lock.endPrompt()   // the lock screen went away first: free the prompt slot
                throw e
            }
            try {
                if (cipher != null) prompt.authenticate(promptInfo(), BiometricPrompt.CryptoObject(cipher))
                else prompt.authenticate(promptInfo())
            } catch (e: RuntimeException) {
                lock.endPrompt()
                Log.w(TAG, "Could not start the prompt", e)
                error = "Couldn't start authentication. Try again."
            }
        }
    }

    // Each time the screen comes up: re-read what the device offers (the user may have just
    // enrolled a fingerprint), and pass through when there is no lock screen at all. Never prompts.
    LaunchedEffect(activity, lock) {
        activity.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            method = unlockMethod(activity)
            if (!hasSecureLock(activity)) unlock()
        }
    }

    LockScreenContent(reason, method, error, onUnlock = ::unlock)
}

@Composable
private fun LockScreenContent(reason: LockReason, method: UnlockMethod, error: String?, onUnlock: () -> Unit) {
    val c = LocalPT.current
    // A gentle entrance; never delays the button (it is tappable at once).
    val appear = remember { Animatable(0f) }
    LaunchedEffect(Unit) { appear.animateTo(1f, tween(450)) }
    PTBackground(glow = 0.7f) {
        // Centred when it fits; scrolls (landscape, large text) when it doesn't.
        BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Column(
                Modifier
                    .verticalScroll(rememberScrollState())
                    .fillMaxWidth()
                    .heightIn(min = maxHeight)
                    .padding(horizontal = 32.dp, vertical = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.weight(1f))
                Column(
                    Modifier.graphicsLayer {
                        alpha = appear.value
                        translationY = (1f - appear.value) * 24.dp.toPx()
                    },
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    AppIcon(96.dp)
                    Spacer(Modifier.height(24.dp))
                    Text("Passthrough", style = PT.display(32.sp), color = c.primary, modifier = Modifier.semantics { heading() })
                    Spacer(Modifier.height(8.dp))
                    Row(
                        Modifier.background(c.fill, CircleShape).padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Filled.Lock, null, tint = c.secondary, modifier = Modifier.size(13.dp))
                        Text("Locked", style = PT.display(13.sp, FontWeight.SemiBold), color = c.secondary)
                    }
                    Spacer(Modifier.height(16.dp))
                    Text(
                        reason.message, style = PT.display(16.sp, FontWeight.Normal), color = c.secondary, textAlign = TextAlign.Center,
                        modifier = Modifier.widthIn(max = 340.dp),
                    )
                }
                Spacer(Modifier.height(32.dp))
                AnimatedVisibility(error != null, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                    ErrorNote(error.orEmpty())
                }
                Button(
                    onClick = onUnlock,
                    modifier = Modifier.fillMaxWidth().widthIn(max = 360.dp).heightIn(min = 56.dp),
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color.White),
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 56.dp).background(PT.accent, CircleShape).padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
                    ) {
                        Icon(method.icon, null, modifier = Modifier.size(22.dp))
                        Spacer(Modifier.size(10.dp))
                        Text(method.label, style = PT.display(17.sp, FontWeight.Bold), textAlign = TextAlign.Center)
                    }
                }
                method.hint?.let {
                    Spacer(Modifier.height(12.dp))
                    Text(it, style = PT.display(13.sp, FontWeight.Normal), color = c.secondary, textAlign = TextAlign.Center)
                }
                Spacer(Modifier.weight(1f))
                Spacer(Modifier.height(24.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Shield, null, tint = c.tertiary, modifier = Modifier.size(14.dp))
                    Text("Locking doesn't stop sharing with your Mac.", style = PT.display(12.sp, FontWeight.Normal), color = c.tertiary,
                        textAlign = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
private fun ErrorNote(text: String) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier
            .padding(bottom = 16.dp)
            .widthIn(max = 360.dp)
            .fillMaxWidth()
            .background(PT.danger.copy(alpha = 0.12f), shape)
            .border(1.dp, PT.danger.copy(alpha = 0.25f), shape)
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.ErrorOutline, null, tint = PT.danger, modifier = Modifier.size(18.dp))
        Text(text, style = PT.display(14.sp, FontWeight.Medium), color = PT.danger)
    }
}

/**
 * The app icon as a rounded tile, from a full-resolution copy (`app_mark`, written by
 * scripts/make_icons.swift): the launcher layers are sized for the launcher and blur larger.
 */
@Composable
internal fun AppIcon(size: Dp) {
    val shape = RoundedCornerShape(size * 0.26f)
    Image(
        painterResource(R.drawable.app_mark), null,
        Modifier
            .shadow(24.dp, shape, ambientColor = PT.accentStart.copy(alpha = 0.5f), spotColor = PT.accentEnd.copy(alpha = 0.5f))
            .size(size)
            .clip(shape),
        contentScale = ContentScale.Crop,
    )
}

private val LockReason.message: String
    get() = when (this) {
        LockReason.STARTUP -> "Your Macs and Remote shell stay private until you unlock."
        LockReason.AWAY -> "Locked after a minute away, to keep your Macs and Remote shell private."
        LockReason.SHELL_KEY -> "A Mac just shared Remote shell with this phone. Unlock to finish setting it up."
    }

/** What the Unlock button names, from what the device can check. */
private enum class UnlockMethod(val label: String, val icon: ImageVector, val hint: String?) {
    FINGERPRINT("Unlock with fingerprint", Icons.Filled.Fingerprint, "Or use your PIN, pattern or password."),
    FACE("Unlock with face", Icons.Filled.Face, "Or use your PIN, pattern or password."),
    BIOMETRIC("Unlock with biometrics", Icons.Filled.Fingerprint, "Or use your PIN, pattern or password."),
    SCREEN_LOCK("Unlock with screen lock", Icons.Filled.LockOpen, "Use your phone's PIN, pattern or password."),
    NONE("Open Passthrough", Icons.Filled.LockOpen, null),
}

private fun unlockMethod(activity: FragmentActivity): UnlockMethod {
    if (!hasSecureLock(activity)) return UnlockMethod.NONE
    val strong = BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
    if (!strong) return UnlockMethod.SCREEN_LOCK
    val pm = activity.packageManager
    val finger = pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
    val face = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && pm.hasSystemFeature(PackageManager.FEATURE_FACE)
    return when {
        finger && !face -> UnlockMethod.FINGERPRINT
        face && !finger -> UnlockMethod.FACE
        else -> UnlockMethod.BIOMETRIC
    }
}

/**
 * API 30+: strong biometrics or the device credential only. A weak (class 2) biometric
 * gives Keystore no auth token, so it would leave the shell key vault
 * (AUTH_BIOMETRIC_STRONG | AUTH_DEVICE_CREDENTIAL) locked after an app unlock.
 */
private const val AUTHENTICATORS = BIOMETRIC_STRONG or DEVICE_CREDENTIAL

/**
 * False only when there is nothing to authenticate with: on API 30+ the prompt's own
 * authenticator set reports nothing enrolled and the keyguard agrees (both must say so,
 * so a transient biometric error never skips the prompt).
 */
private fun hasSecureLock(activity: FragmentActivity): Boolean {
    val keyguardSecure = activity.getSystemService(KeyguardManager::class.java)?.isDeviceSecure ?: true
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return keyguardSecure
    val result = BiometricManager.from(activity).canAuthenticate(AUTHENTICATORS)
    return !(result == BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED && !keyguardSecure)
}

@Suppress("DEPRECATION")
private fun promptInfo(): BiometricPrompt.PromptInfo {
    val builder = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Unlock Passthrough")
        .setSubtitle("Confirm it's you to open your Macs and Remote shell")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        builder.setAllowedAuthenticators(AUTHENTICATORS)
    } else {
        // STRONG|DEVICE_CREDENTIAL is unsupported before API 30; this is the legacy equivalent.
        builder.setDeviceCredentialAllowed(true)
    }
    return builder.build()
}
