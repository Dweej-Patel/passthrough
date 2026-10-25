package dev.dpatel.passthrough.ui.mac

import android.content.SharedPreferences
import android.os.Build
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PriorityHigh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacFormat
import dev.dpatel.passthrough.core.hasLid
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.shell.ShellReach
import dev.dpatel.passthrough.ui.shell.ShellViewModel

/** When Step away last happened, for the Activity tab ("since you stepped away"). */
internal object StepAway {
    private const val KEY = "stepAway.at"

    fun markNow(prefs: SharedPreferences) = prefs.edit().putLong(KEY, System.currentTimeMillis()).apply()

    /** Unix seconds, if within the last day. */
    fun since(prefs: SharedPreferences): Double? {
        val at = prefs.getLong(KEY, 0)
        return if (at > 0 && System.currentTimeMillis() - at < 86_400_000) at / 1000.0 else null
    }
}

/**
 * Before leaving the Mac: what would bite once you're gone, each with a fix
 * where this phone can make one. "Step away" then switches to Away; it's
 * disabled, with the reason, when this phone can't change the Mac.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun StepAwaySheet(
    shell: ShellViewModel, online: Boolean,
    onDismiss: () -> Unit, onSwitchNow: () -> Unit, onStepAway: () -> Unit,
) {
    val c = LocalPT.current
    val state by shell.macState.collectAsStateWithLifecycle()
    val reach by shell.reach.collectAsStateWithLifecycle()
    val sessions by shell.sessions.collectAsStateWithLifecycle()
    val macs by shell.macs.collectAsStateWithLifecycle()
    val selected by shell.selectedMacID.collectAsStateWithLifecycle()
    val canControl = reach == ShellReach.READY && state?.control == true
    val fromAnywhere = macs.firstOrNull { it.macID == selected }?.irohID != null

    data class Check(val ok: Boolean, val title: String, val detail: String, val fix: Pair<String, () -> Unit>? = null)
    val checks = buildList {
        val s = state
        if (s?.awake == true) add(Check(true, if (s.hasLid) "Stays awake, even with the lid closed" else "Stays awake",
            if (s.hasLid) "It still sleeps at its battery limit or if it gets hot." else "It still sleeps if it gets hot."))
        else add(Check(false, "It will sleep",
            if (canControl) "Keep awake is off, so shells pause once it sleeps." else "Keep awake is off. Turn it on at the Mac, or allow Awake & VPN for this phone there.",
            if (canControl) "Turn on" to { shell.control(MacControl.Awake(true)) } else null))
        val battery = s?.battery
        if (s != null && battery != null) {
            val minutes = s.minutesLeft
            when {
                s.charging == true -> add(Check(true, "Plugged in", "${MacFormat.percent(battery)} and charging."))
                minutes != null -> add(Check(minutes >= 120, MacFormat.duration(minutes) + " on battery",
                    if (minutes < 120) "Plug it in if you'll be gone longer." else "Until its ${MacFormat.percent(s.batteryFloor ?: 0.0)} limit, at the current rate."))
                else -> add(Check(battery > 0.5, "${MacFormat.percent(battery)} on battery", "Plug it in if you'll be gone a while."))
            }
        }
        if (online) add(Check(false, "Online through this phone",
            "When you take it, the Mac falls back to its own Wi-Fi. Switch now to be sure it's online before you go.", "Switch now" to onSwitchNow))
        else add(Check(true, "On its own connection", "It doesn't need this phone to stay online."))
        if (fromAnywhere) add(Check(true, "Reachable from anywhere", "Its shell, from any network."))
        else add(Check(false, "Reachable on this network only", "Turn on Reach this Mac from anywhere in Passthrough's Remote Shell settings on the Mac."))
        val running = sessions.count { it.running }
        if (running > 0) add(Check(true, if (running == 1) "1 shell keeps running" else "$running shells keep running",
            if (fromAnywhere) "Pick them up from here, or from anywhere." else "Pick them up from here, from this network."))
    }
    val issues = checks.count { !it.ok }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Before you go", style = PT.display(22.sp), color = c.primary)
            Spacer(Modifier.height(8.dp))
            checks.forEachIndexed { i, check ->
                Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Box(Modifier.size(26.dp).background(if (check.ok) c.tint else PT.attention, CircleShape), contentAlignment = Alignment.Center) {
                        Icon(if (check.ok) Icons.Filled.Check else Icons.Filled.PriorityHigh, if (check.ok) "OK" else "Needs attention",
                            tint = if (check.ok) PT.onTint else PT.onAttention, modifier = Modifier.size(15.dp))
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(check.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary)
                        Text(check.detail, style = PT.display(13.sp, FontWeight.Normal), color = c.secondary)
                    }
                    check.fix?.let { (label, action) ->
                        OutlinedButton(onClick = action, modifier = Modifier.heightIn(min = 44.dp)) { Text(label, color = c.attentionText) }
                    }
                }
                if (i < checks.size - 1) HorizontalDivider(Modifier.padding(start = 40.dp), color = c.cardBorder)
            }
            Spacer(Modifier.height(16.dp))
            PrimaryButton("Step away", onStepAway, Icons.AutoMirrored.Filled.DirectionsWalk, enabled = canControl)
            Text(
                when {
                    reach != ShellReach.READY -> "Can't reach your Mac right now, so this phone can't switch it to Away."
                    !canControl -> "Your Mac doesn't let this phone change Keep awake. Turn on Awake & VPN for it in Passthrough's Remote Shell settings on the Mac."
                    issues == 0 -> "Switches to Away: Keep awake on, off this phone's connection."
                    issues == 1 -> "1 thing above may stop it working while you're gone."
                    else -> "$issues things above may stop it working while you're gone."
                },
                style = PT.display(12.sp, FontWeight.Normal), color = c.secondary,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

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
