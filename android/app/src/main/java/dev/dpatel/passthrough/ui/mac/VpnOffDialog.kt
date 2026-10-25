package dev.dpatel.passthrough.ui.mac

import android.os.Build
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT

/**
 * Turning the Mac's VPN off from the phone lowers protection: say what
 * changes, then the system biometric (or screen lock) prompt. Turning it on
 * never comes through here.
 */
@Composable
internal fun VpnOffDialog(
    macName: String, killSwitch: Boolean, reason: String, activity: FragmentActivity?,
    onDismiss: () -> Unit, onConfirmed: () -> Unit,
) {
    val c = LocalPT.current
    var failure by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Turn VPN off?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(reason, style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
                Text(
                    "$macName's traffic will leave without the VPN${if (killSwitch) ", and the kill switch turns off too" else ""}.",
                    modifier = Modifier.fillMaxWidth().background(PT.attention.copy(alpha = 0.1f), RoundedCornerShape(12.dp)).padding(12.dp),
                )
                Text("Your fingerprint, face or screen lock confirms it. The Mac shows a notice. Turning the VPN back on never asks.",
                    style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                failure?.let { Text(it, color = c.attentionText, style = PT.display(12.sp, FontWeight.SemiBold)) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val host = activity ?: return@TextButton run { failure = "Couldn't confirm it's you. The VPN stays on." }
                confirmIdentity(host, macName, onConfirmed) { failure = it }
            }) { Text("Turn VPN off", color = c.attentionText) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Keep VPN on", color = c.tintText) } },
    )
}

@Suppress("DEPRECATION")
private fun confirmIdentity(activity: FragmentActivity, macName: String, onSuccess: () -> Unit, onFailure: (String) -> Unit) {
    val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onSuccess()
        override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
            when (errorCode) {
                BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_CANCELED -> Unit
                // No screen lock at all: nothing to check, as the app lock does.
                BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL -> onSuccess()
                else -> onFailure("Couldn't confirm it's you. The VPN stays on.")
            }
        }
    })
    val info = BiometricPrompt.PromptInfo.Builder()
        .setTitle("Turn the VPN off on $macName")
        .setSubtitle("Confirm it's you")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) info.setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
    else info.setDeviceCredentialAllowed(true)
    prompt.authenticate(info.build())
}
