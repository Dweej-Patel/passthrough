package dev.dpatel.passthrough.ui

import android.content.Intent
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Usb
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import dev.dpatel.passthrough.core.ByteFormat
import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.service.ServiceState
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun HomeScreen(vm: AppViewModel, onPower: () -> Unit, onPair: () -> Unit, onSettings: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    PTBackground(glow = if (state == ServiceState.Running) 1f else 0.45f) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp)
                .padding(top = 8.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Header(vm, onSettings)
            HeroCard(vm, onPower, onPair)
            FlowCard(vm)
            ThroughputCard(vm)
            UsageCard(vm)
            MacsCard(vm, onPair)
            Text(
                "Traffic between the Mac and this phone travels only over the USB cable. The Mac's connections are opened by this phone's own network stack.",
                style = PT.display(12.sp, FontWeight.Normal), color = LocalPT.current.tertiary, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            )
        }
    }
}

@Composable
private fun Header(vm: AppViewModel, onSettings: () -> Unit) {
    val c = LocalPT.current
    val state by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val subtitle = when (state) {
        ServiceState.Running -> stats.macs.size.let { n -> if (n == 0) "Waiting for a Mac on USB" else "Serving ${if (n == 1) "1 Mac" else "$n Macs"} over USB" }
        ServiceState.Starting -> "Starting…"
        ServiceState.Stopping -> "Stopping…"
        is ServiceState.Failed -> "Something went wrong"
        ServiceState.Stopped -> "USB internet for your Mac"
    }
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Passthrough", style = PT.display(30.sp), color = c.primary)
            Text(subtitle, style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
        }
        Box(
            Modifier.size(42.dp).background(c.card, CircleShape).clickable(onClick = onSettings).semantics { contentDescription = "Settings" },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Settings, null, tint = c.secondary, modifier = Modifier.size(22.dp)) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroCard(vm: AppViewModel, onPower: () -> Unit, onPair: () -> Unit) {
    val c = LocalPT.current
    val context = LocalContext.current
    val state by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val radio by vm.radio.collectAsStateWithLifecycle()
    val paired by vm.pairedClients.collectAsStateWithLifecycle()
    val usbDebugging by vm.usbDebugging.collectAsStateWithLifecycle()
    val mode = when (state) {
        ServiceState.Running -> RingMode.LIVE
        ServiceState.Starting, ServiceState.Stopping -> RingMode.BUSY
        is ServiceState.Failed -> RingMode.ERROR
        ServiceState.Stopped -> RingMode.IDLE
    }
    val statusLine = when (state) {
        ServiceState.Stopped -> "Tap to start sharing this phone's connection"
        ServiceState.Starting -> "Bringing the proxy up"
        ServiceState.Stopping -> "Shutting down"
        is ServiceState.Failed -> "Could not start"
        ServiceState.Running -> stats.macs.firstOrNull()?.let { "${it.name} is online through this phone" }
            ?: "Ready. Plug in your Mac and connect from the menu bar."
    }
    PTCard(padding = 22.dp) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Box(Modifier.padding(top = 4.dp), contentAlignment = Alignment.Center) {
                StatusRing(mode)
                PowerButton(isOn = state.isActive, busy = state == ServiceState.Starting || state == ServiceState.Stopping, onClick = onPower)
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(statusLine, style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary, textAlign = TextAlign.Center)
                (state as? ServiceState.Failed)?.let {
                    Text(it.message, style = PT.display(12.sp, FontWeight.Normal), color = PT.danger, textAlign = TextAlign.Center)
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    radio?.let { PTPill(it, Icons.Filled.CellTower, PT.down) }
                    PTPill("USB", Icons.Filled.Usb)
                    PTPill("Background", Icons.Filled.Bedtime)
                    if (state == ServiceState.Running) PTPill("${stats.active} open", Icons.Filled.SwapHoriz, PT.up)
                }
            }
            if (!usbDebugging) {
                Column(
                    Modifier.fillMaxWidth().background(PT.warning.copy(alpha = 0.12f), androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Warning, null, tint = PT.warning, modifier = Modifier.size(16.dp))
                        Text("USB debugging is off", style = PT.display(14.sp, FontWeight.SemiBold), color = PT.warning)
                    }
                    Text("The Mac reaches this phone through Android's USB debugging bridge. Turn it on in Developer options (tap Build number seven times in About phone to reveal them).",
                        style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                    TextButton(onClick = {
                        val dev = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        runCatching { context.startActivity(dev) }.onFailure {
                            runCatching { context.startActivity(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        }
                    }, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) { Text("Open Developer options", color = PT.warning) }
                }
            }
            if (paired.isEmpty() && state == ServiceState.Running) {
                Button(
                    onClick = onPair, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = PT.accentEnd, contentColor = androidx.compose.ui.graphics.Color.White),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 12.dp),
                ) {
                    Icon(Icons.Filled.Devices, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Pair your Mac", style = PT.display(15.sp, FontWeight.SemiBold))
                }
            }
        }
    }
}

@Composable
private fun FlowCard(vm: AppViewModel) {
    val state by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val meter by vm.meter.collectAsStateWithLifecycle()
    val radio by vm.radio.collectAsStateWithLifecycle()
    val name by vm.settings.deviceName.collectAsStateWithLifecycle()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val macs = stats.macs
    val flow = FlowMapState(
        macName = if (macs.size > 1) "${macs.size} Macs" else macs.firstOrNull()?.name ?: "Mac",
        phoneName = name,
        linkUp = state == ServiceState.Running && macs.isNotEmpty(),
        busy = state == ServiceState.Starting || (state == ServiceState.Running && macs.isEmpty()),
        radio = radio, downRate = meter.downRate, upRate = meter.upRate, activeConnections = stats.active,
    )
    PTCard(padding = 10.dp) {
        PTSectionTitle("How it flows", Modifier.padding(start = 6.dp, bottom = 4.dp), icon = Icons.Filled.Hub)
        FlowMap(flow, active = lifecycle.isAtLeast(Lifecycle.State.RESUMED))
    }
}

@Composable
private fun ThroughputCard(vm: AppViewModel) {
    val c = LocalPT.current
    val stats by vm.stats.collectAsStateWithLifecycle()
    val meter by vm.meter.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val now by vm.now.collectAsStateWithLifecycle()
    PTCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PTSectionTitle("Live throughput", Modifier.weight(1f), icon = Icons.AutoMirrored.Filled.ShowChart)
                val started = stats.startedAt
                if (started != null && state == ServiceState.Running) {
                    Text(ByteFormat.duration((now - started) / 1000), style = PT.mono(12.sp), color = c.secondary)
                }
            }
            Row(verticalAlignment = Alignment.Bottom) {
                RateReadout(meter.downRate, down = true)
                Spacer(Modifier.weight(1f))
                RateReadout(meter.upRate, down = false)
            }
            ThroughputChart(meter.history)
            Row {
                StatCell("Session down", ByteFormat.bytes(stats.rx), PT.down, Modifier.weight(1f))
                StatCell("Session up", ByteFormat.bytes(stats.tx), PT.up, Modifier.weight(1f))
                StatCell("Connections", "${stats.totalConnections}", modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun UsageCard(vm: AppViewModel) {
    val c = LocalPT.current
    val usage by vm.usage.collectAsStateWithLifecycle()
    var confirm by remember { mutableStateOf(false) }
    val since = remember(usage.monthStart) { SimpleDateFormat("MMMM d", Locale.getDefault()).format(Date(usage.monthStart)) }
    PTCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PTSectionTitle("Data used", Modifier.weight(1f), icon = Icons.Filled.BarChart)
                Text("Reset month", style = PT.display(12.sp, FontWeight.SemiBold), color = c.secondary,
                    modifier = Modifier.clickable { confirm = true }.padding(4.dp))
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(ByteFormat.bytes(usage.monthTotal), style = PT.mono(28.sp, FontWeight.Bold), color = c.primary)
                    Text("since $since", style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                }
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(ByteFormat.bytes(usage.allTotal), style = PT.mono(17.sp, FontWeight.SemiBold), color = c.primary)
                    Text("all time", style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                }
            }
            UsageBar(usage.monthRx.toDouble(), usage.monthTx.toDouble())
        }
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Reset this month's counter?") },
            confirmButton = { TextButton(onClick = { vm.resetMonth(); confirm = false }) { Text("Reset", color = PT.danger) } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun MacsCard(vm: AppViewModel, onPair: () -> Unit) {
    val c = LocalPT.current
    val clients by vm.pairedClients.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val now by vm.now.collectAsStateWithLifecycle()
    val connected = stats.macs.map { it.id }.toSet()
    PTCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PTSectionTitle("Paired Macs", Modifier.weight(1f), icon = Icons.Filled.LaptopMac)
                FilledTonalButton(
                    onClick = onPair,
                    colors = ButtonDefaults.filledTonalButtonColors(containerColor = PT.accentEnd.copy(alpha = 0.16f), contentColor = PT.accentEnd),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    modifier = Modifier.padding(0.dp),
                ) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.size(4.dp))
                    Text("Pair", style = PT.display(12.sp, FontWeight.Bold))
                }
            }
            if (clients.isEmpty()) {
                Text("No Mac paired yet. Start the proxy, then tap Pair and enter the code in Passthrough on your Mac.",
                    style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
            } else {
                clients.forEach { client -> MacRow(vm, client, live = client.id in connected, now = now) }
            }
        }
    }
}

@Composable
private fun MacRow(vm: AppViewModel, client: PairedClient, live: Boolean, now: Long) {
    val c = LocalPT.current
    var menu by remember { mutableStateOf(false) }
    val detail = when {
        live -> "Connected now"
        client.lastSeen != null -> "Last seen ${DateUtils.getRelativeTimeSpanString(client.lastSeen, now, DateUtils.MINUTE_IN_MILLIS)}"
        else -> "Paired ${DateUtils.getRelativeTimeSpanString(client.pairedAt, now, DateUtils.MINUTE_IN_MILLIS)}"
    }
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        PTStatusDot(if (live) PT.success else c.secondary.copy(alpha = 0.5f), live)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(client.name, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary)
            Text(detail, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
        }
        Box {
            Icon(Icons.Filled.MoreHoriz, "Options for ${client.name}", tint = c.secondary,
                modifier = Modifier.size(28.dp).clickable { menu = true }.padding(2.dp))
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("Forget this Mac", color = PT.danger) },
                    leadingIcon = { Icon(Icons.Filled.Delete, null, tint = PT.danger) },
                    onClick = { menu = false; vm.revoke(client) },
                )
            }
        }
    }
}
