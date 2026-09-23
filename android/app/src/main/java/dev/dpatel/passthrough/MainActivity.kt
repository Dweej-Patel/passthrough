package dev.dpatel.passthrough

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.ui.AppViewModel
import dev.dpatel.passthrough.ui.HomeScreen
import dev.dpatel.passthrough.ui.PairSheet
import dev.dpatel.passthrough.ui.PassthroughTheme
import dev.dpatel.passthrough.ui.SettingsScreen

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { PassthroughTheme { AppRoot(vm) } }
    }

    /** Asked once, just before the first start: the service's notification. */
    private fun missingPermissions(): Array<String> {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return wanted.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }.toTypedArray()
    }

    @Composable
    private fun AppRoot(vm: AppViewModel) {
        var showSettings by rememberSaveable { mutableStateOf(false) }
        var showPairing by rememberSaveable { mutableStateOf(false) }
        val prefs = Runtime.settings.prefs
        val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { vm.start() }
        val onPower = {
            val missing = missingPermissions()
            if (!vm.state.value.isActive && missing.isNotEmpty() && !prefs.getBoolean(ASKED_KEY, false)) {
                prefs.edit().putBoolean(ASKED_KEY, true).apply()
                permissions.launch(missing)
            } else vm.toggle()
        }

        BackHandler(enabled = showSettings) { showSettings = false }
        AnimatedContent(
            targetState = showSettings,
            transitionSpec = {
                if (targetState) slideInHorizontally { it } togetherWith fadeOut()
                else fadeIn() togetherWith slideOutHorizontally { it }
            },
            label = "screen",
        ) { settings ->
            if (settings) SettingsScreen(vm, onDone = { showSettings = false })
            else HomeScreen(vm, onPower = onPower, onPair = { showPairing = true }, onSettings = { showSettings = true })
        }
        if (showPairing) PairSheet(vm, onDismiss = { showPairing = false; vm.endPairing() })
    }

    companion object { private const val ASKED_KEY = "permissions.asked" }
}
