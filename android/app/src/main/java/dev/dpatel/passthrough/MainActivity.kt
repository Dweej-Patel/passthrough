package dev.dpatel.passthrough

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.ui.AppViewModel
import dev.dpatel.passthrough.ui.HomeScreen
import dev.dpatel.passthrough.ui.PairSheet
import dev.dpatel.passthrough.ui.PassthroughTheme
import dev.dpatel.passthrough.ui.SettingsScreen
import dev.dpatel.passthrough.ui.lock.LockGate
import dev.dpatel.passthrough.ui.lock.LockModel
import dev.dpatel.passthrough.ui.shell.ShellHistoryScreen
import dev.dpatel.passthrough.ui.shell.ShellViewModel
import dev.dpatel.passthrough.ui.shell.TerminalIntent
import dev.dpatel.passthrough.ui.shell.TerminalScreen

class MainActivity : FragmentActivity() {
    private val vm: AppViewModel by viewModels()
    private val lockModel: LockModel by viewModels()
    private val shell: ShellViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            PassthroughTheme { LockGate(lockModel.lock, this@MainActivity) { AppRoot(vm, shell) } }
        }
    }

    /** Asked once, just before the first start: the service's notification. */
    private fun missingPermissions(): Array<String> {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return wanted.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }.toTypedArray()
    }

    private enum class Screen { HOME, SETTINGS, TERMINAL, HISTORY }

    /** Composed only while unlocked: relocking tears down every screen (terminal and history included). */
    @Composable
    private fun AppRoot(vm: AppViewModel, shell: ShellViewModel) {
        var screen by rememberSaveable { mutableStateOf(Screen.HOME) }
        var terminalIntent by rememberSaveable { mutableStateOf(TerminalIntent.RESUME) }
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

        // Relock removes the pair sheet from composition; don't leave its code valid behind the lock,
        // nor shell keys in memory.
        DisposableEffect(Unit) {
            onDispose {
                if (!isChangingConfigurations) {
                    vm.endPairing()
                    shell.onLocked()
                }
            }
        }
        // Runs right after each unlock (and again, harmlessly, on rotation): inside the shell key
        // vault's 60 s window, so pending keys are adopted and read now.
        LaunchedEffect(Unit) { shell.onUnlocked(lockModel.lock) }
        val lifecycleOwner = LocalLifecycleOwner.current
        DisposableEffect(lifecycleOwner) {
            val observer = LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_STOP -> if (!isChangingConfigurations) shell.onBackground()
                    Lifecycle.Event.ON_START -> shell.onForeground()
                    else -> Unit
                }
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
        }
        BackHandler(enabled = screen != Screen.HOME) { screen = Screen.HOME }
        AnimatedContent(
            targetState = screen,
            transitionSpec = {
                when {
                    targetState == Screen.TERMINAL -> slideInVertically { it } togetherWith fadeOut()
                    initialState == Screen.TERMINAL -> fadeIn() togetherWith slideOutVertically { it }
                    targetState != Screen.HOME -> slideInHorizontally { it } togetherWith fadeOut()
                    else -> fadeIn() togetherWith slideOutHorizontally { it }
                }
            },
            label = "screen",
        ) { target ->
            when (target) {
                Screen.SETTINGS -> SettingsScreen(vm, shell, onDone = { screen = Screen.HOME })
                Screen.TERMINAL -> TerminalScreen(
                    shell, terminalIntent,
                    onIntentStarted = { terminalIntent = TerminalIntent.RESUME },
                    onClose = { screen = Screen.HOME },
                )
                Screen.HISTORY -> ShellHistoryScreen(shell, onDone = { screen = Screen.HOME })
                Screen.HOME -> HomeScreen(
                    vm, shell, onPower = onPower, onPair = { showPairing = true }, onSettings = { screen = Screen.SETTINGS },
                    onOpenTerminal = { session ->
                        terminalIntent = session?.let(TerminalIntent::attach) ?: TerminalIntent.NEW
                        screen = Screen.TERMINAL
                    },
                    onShellHistory = { screen = Screen.HISTORY },
                )
            }
        }
        if (showPairing) PairSheet(vm, onDismiss = { showPairing = false; vm.endPairing() })
    }

    companion object { private const val ASKED_KEY = "permissions.asked" }
}
