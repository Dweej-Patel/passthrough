package dev.dpatel.passthrough.ui.lock

import android.app.KeyguardManager
import android.os.Build
import android.util.Log
import android.view.WindowManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.repeatOnLifecycle
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTBackground

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

/** Keeps content out of the Recents thumbnail (and screenshots on API < 33). */
@Composable
private fun PrivacyWindow(activity: FragmentActivity) {
    DisposableEffect(activity) {
        if (Build.VERSION.SDK_INT >= 33) {
            activity.setRecentsScreenshotEnabled(false)
        } else {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        onDispose {
            if (Build.VERSION.SDK_INT >= 33) activity.setRecentsScreenshotEnabled(true)
            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}

@Composable
private fun LockScreen(lock: AppLock, activity: FragmentActivity) {
    var error by remember { mutableStateOf<String?>(null) }

    val prompt = remember(activity) {
        BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    error = null
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
                            error = errString.toString()
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
        try {
            prompt.authenticate(promptInfo())
        } catch (e: RuntimeException) {
            lock.endPrompt()
            Log.w(TAG, "Could not start the prompt", e)
            error = "Couldn't start authentication."
        }
    }

    // Once per foregrounding: cancelling doesn't loop; the Unlock button re-prompts.
    LaunchedEffect(activity, lock) {
        activity.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            if (lock.takeAutoPrompt()) unlock()
        }
    }

    val c = LocalPT.current
    PTBackground(glow = 0.45f) {
        Column(
            Modifier.align(Alignment.Center).padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = PT.down, modifier = Modifier.size(64.dp))
            Spacer(Modifier.height(18.dp))
            Text("Passthrough", style = PT.display(30.sp), color = c.primary)
            error?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, color = PT.danger, textAlign = TextAlign.Center, fontSize = 14.sp)
            }
            Spacer(Modifier.height(22.dp))
            Button(onClick = { unlock() }) {
                Icon(Icons.Filled.LockOpen, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text("Unlock")
            }
        }
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
    val builder = BiometricPrompt.PromptInfo.Builder().setTitle("Unlock Passthrough")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        builder.setAllowedAuthenticators(AUTHENTICATORS)
    } else {
        // STRONG|DEVICE_CREDENTIAL is unsupported before API 30; this is the legacy equivalent.
        builder.setDeviceCredentialAllowed(true)
    }
    return builder.build()
}
