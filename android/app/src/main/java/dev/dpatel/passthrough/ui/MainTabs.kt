package dev.dpatel.passthrough.ui

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dpatel.passthrough.ui.mac.ActivityScreen
import dev.dpatel.passthrough.ui.mac.MacScreen
import dev.dpatel.passthrough.ui.shell.RemoteShellCard
import dev.dpatel.passthrough.ui.shell.ShellViewModel

enum class MainTab { MAC, SHELLS, ACTIVITY, PHONE }

/** The app's sections, as on iOS: the Mac first, its shells, what happened, then this phone's own sharing. */
@Composable
fun MainTabs(
    vm: AppViewModel,
    shell: ShellViewModel,
    initial: MainTab,
    onPower: () -> Unit,
    onPair: () -> Unit,
    onSettings: () -> Unit,
    onOpenTerminal: (String?) -> Unit,
    onShellHistory: () -> Unit,
    phoneScroll: ScrollState,
) {
    val c = LocalPT.current
    var tab by rememberSaveable { mutableStateOf(initial) }
    Scaffold(
        containerColor = c.background,
        contentWindowInsets = WindowInsets(0),
        bottomBar = {
            NavigationBar(containerColor = c.card) {
                listOf(
                    Triple(MainTab.MAC, "Mac", Icons.Filled.Laptop),
                    Triple(MainTab.SHELLS, "Shells", Icons.Filled.Terminal),
                    Triple(MainTab.ACTIVITY, "Activity", Icons.Filled.History),
                    Triple(MainTab.PHONE, "Phone", Icons.Filled.PhoneAndroid),
                ).forEach { (t, label, icon) ->
                    NavigationBarItem(
                        selected = tab == t, onClick = { tab = t },
                        icon = { Icon(icon, null) }, label = { Text(label) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = PT.onTint, indicatorColor = c.tint,
                            selectedTextColor = c.tintText, unselectedIconColor = c.secondary, unselectedTextColor = c.secondary,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().background(c.background).padding(padding)) {
            when (tab) {
                MainTab.MAC -> MacScreen(vm, shell, onPower, onPair, onSettings, onOpenTerminal, onShells = { tab = MainTab.SHELLS })
                MainTab.SHELLS -> ShellsTab(shell, onOpenTerminal, onShellHistory)
                MainTab.ACTIVITY -> ActivityScreen(vm, shell, onOpenTerminal = { onOpenTerminal(it) }, onHistory = onShellHistory)
                MainTab.PHONE -> HomeScreen(vm, onPower = onPower, onPair = onPair, onSettings = onSettings, scroll = phoneScroll)
            }
        }
    }
}

@Composable
private fun ShellsTab(shell: ShellViewModel, onOpenTerminal: (String?) -> Unit, onShellHistory: () -> Unit) {
    Column(
        Modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .verticalScroll(rememberScrollState())
            .fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp)
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Shells", style = PT.display(30.sp), color = LocalPT.current.primary, modifier = Modifier.padding(top = 6.dp))
        RemoteShellCard(shell, onOpen = onOpenTerminal, onHistory = onShellHistory)
    }
}
