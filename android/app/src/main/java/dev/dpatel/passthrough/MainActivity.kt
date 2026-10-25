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
import androidx.compose.foundation.ScrollState
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
import dev.dpatel.passthrough.ui.MainTab
import dev.dpatel.passthrough.ui.MainTabs
import dev.dpatel.passthrough.ui.PairSheet
import dev.dpatel.passthrough.ui.PassthroughTheme
import dev.dpatel.passthrough.ui.PhoneScreen
import dev.dpatel.passthrough.ui.SettingsScreen
import dev.dpatel.passthrough.ui.lock.LockGate
import dev.dpatel.passthrough.ui.lock.LockModel
import dev.dpatel.passthrough.ui.shell.ShellDemo
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

    /** [depth]: how far in from the tabs, so going back slides the way it came. */
    private enum class Screen(val depth: Int) { HOME(0), PHONE(1), HISTORY(1), SETTINGS(2), TERMINAL(1) }

    /** Composed only while unlocked: relocking tears down every screen (terminal and history included). */
    @Composable
    private fun AppRoot(vm: AppViewModel, shell: ShellViewModel) {
        // Debug builds only: where to open, for screenshots (pt.demo.tab = mac|shells|activity, or phone for This phone).
        val demoTab = if (BuildConfig.DEBUG) intent?.getStringExtra("pt.demo.tab") else null
        var screen by rememberSaveable { mutableStateOf(if (demoTab.equals("phone", true)) Screen.PHONE else Screen.HOME) }
        // Where Settings goes back to: the tabs or This phone.
        var settingsFrom by rememberSaveable { mutableStateOf(Screen.HOME) }
        var terminalIntent by rememberSaveable { mutableStateOf(TerminalIntent.RESUME) }
        var showPairing by rememberSaveable { mutableStateOf(false) }
        val startTab = demoTab?.let { v -> MainTab.entries.firstOrNull { it.name.equals(v, true) } } ?: MainTab.MAC
        // Hoisted so the tabs keep their tab and place, and This phone its place, after the screens that replace them.
        var tab by rememberSaveable { mutableStateOf(startTab) }
        val macScroll = rememberSaveable(saver = ScrollState.Saver) { ScrollState(0) }
        val phoneScroll = rememberSaveable(saver = ScrollState.Saver) { ScrollState(0) }
        fun openSettings(from: Screen) { settingsFrom = from; screen = Screen.SETTINGS }
        fun back() { screen = if (screen == Screen.SETTINGS) settingsFrom else Screen.HOME }
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
        // Runs right after each unlock (and again, harmlessly, on rotation): the unlock prompt just
        // opened the shell key vault, so pending keys are adopted and read now.
        LaunchedEffect(Unit) {
            shell.onUnlocked(lockModel.lock)
            // Debug builds only: sample Remote shell state for UI work (see ShellDemo).
            if (BuildConfig.DEBUG) intent?.getStringExtra(ShellDemo.EXTRA)?.let(shell::startDemo)
        }
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
        BackHandler(enabled = screen != Screen.HOME) { back() }
        AnimatedContent(
            targetState = screen,
            transitionSpec = {
                when {
                    targetState == Screen.TERMINAL -> slideInVertically { it } togetherWith fadeOut()
                    initialState == Screen.TERMINAL -> fadeIn() togetherWith slideOutVertically { it }
                    targetState.depth > initialState.depth -> slideInHorizontally { it } togetherWith fadeOut()
                    else -> fadeIn() togetherWith slideOutHorizontally { it }
                }
            },
            label = "screen",
        ) { target ->
            when (target) {
                Screen.SETTINGS -> SettingsScreen(vm, shell, onDone = { back() })
                Screen.PHONE -> PhoneScreen(
                    vm, onPower = onPower, onPair = { showPairing = true }, onSettings = { openSettings(Screen.PHONE) },
                    onDone = { screen = Screen.HOME }, scroll = phoneScroll,
                )
                Screen.TERMINAL -> TerminalScreen(
                    shell, terminalIntent,
                    onIntentStarted = { terminalIntent = TerminalIntent.RESUME },
                    onClose = { screen = Screen.HOME },
                )
                Screen.HISTORY -> ShellHistoryScreen(shell, onDone = { screen = Screen.HOME })
                Screen.HOME -> MainTabs(
                    vm, shell, tab = tab, onTab = { tab = it },
                    onPower = onPower, onPair = { showPairing = true }, onSettings = { openSettings(Screen.HOME) },
                    onThisPhone = { screen = Screen.PHONE },
                    onOpenTerminal = { session ->
                        terminalIntent = session?.let(TerminalIntent::attach) ?: TerminalIntent.NEW
                        screen = Screen.TERMINAL
                    },
                    onShellHistory = { screen = Screen.HISTORY },
                    macScroll = macScroll,
                )
            }
        }
        if (showPairing) PairSheet(vm, onDismiss = { showPairing = false; vm.endPairing() })
    }

    companion object { private const val ASKED_KEY = "permissions.asked" }
}
