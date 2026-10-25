package dev.dpatel.passthrough.ui.mac

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.ByteFormat
import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacFormat
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.ShellPath
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.core.isAsking
import dev.dpatel.passthrough.ui.AppViewModel
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.PTCircleIconButton
import dev.dpatel.passthrough.ui.PTSteps
import dev.dpatel.passthrough.ui.openDeveloperOptions
import dev.dpatel.passthrough.ui.tabInsets
import dev.dpatel.passthrough.ui.shell.ShellFormat
import dev.dpatel.passthrough.ui.shell.ShellReach
import dev.dpatel.passthrough.ui.shell.ShellViewModel

/**
 * The Mac tab: shells waiting on a question first, then the Mac and how it's
 * reached (or pairing, the first time), three plain switches (Internet
 * through this phone, Keep Mac awake, VPN), its shells, and "This phone".
 * A switch that can't change says why under it, with a fix where this phone
 * has one. Turning the VPN off asks for the biometric first; turning
 * anything on never asks.
 */
@Composable
fun MacScreen(
    vm: AppViewModel,
    shell: ShellViewModel,
    onPower: () -> Unit,
    onPair: () -> Unit,
    onSettings: () -> Unit,
    onThisPhone: () -> Unit,
    onOpenTerminal: (String?) -> Unit,
    onShells: () -> Unit,
    scroll: ScrollState,
) {
    val c = LocalPT.current
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val service by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val paired by vm.pairedClients.collectAsStateWithLifecycle()
    val usbDebugging by vm.usbDebugging.collectAsStateWithLifecycle()
    val reach by shell.reach.collectAsStateWithLifecycle()
    val macs by shell.macs.collectAsStateWithLifecycle()
    val selected by shell.selectedMacID.collectAsStateWithLifecycle()
    val sessions by shell.sessions.collectAsStateWithLifecycle()
    val path by shell.path.collectAsStateWithLifecycle()
    val state by shell.macState.collectAsStateWithLifecycle()
    val pending by shell.pendingControl.collectAsStateWithLifecycle()
    val controlError by shell.controlError.collectAsStateWithLifecycle()
    val redialing by shell.redialing.collectAsStateWithLifecycle()

    val isPaired = paired.isNotEmpty() || macs.isNotEmpty()
    val macID = selected ?: paired.firstOrNull()?.id
    val macName = macs.firstOrNull { it.macID == selected }?.macName ?: paired.firstOrNull()?.name ?: "Your Mac"
    val online = macID != null && stats.macs.any { it.id == macID }
    val running = sessions.filter { it.running }

    // Saved across rotation.
    var confirmSleep by rememberSaveable { mutableStateOf(false) }
    var askVpnOff by rememberSaveable { mutableStateOf(false) }
    var lastTapped by rememberSaveable { mutableStateOf<MacSwitch?>(null) }

    /** Pairing needs this phone sharing: start it on the way. */
    val pair = { if (!service.isActive) onPower(); onPair() }

    val link = MacLink(paired = isPaired, reach = reach, macName = macName)
    val block = MacSwitches.macBlock(link, state, controlError)
    val internet = MacSwitches.internet(
        service, macsOnline = stats.macs.size, paired = paired.isNotEmpty(), usbDebugging = usbDebugging,
        elsewhere = state?.internet == true && !service.isActive,
    )
    val awake = MacSwitches.awake(state, block != null, macName, pending, controlError, lastTapped)
    val vpn = MacSwitches.vpn(state, block != null, macName, pending, controlError, lastTapped)

    fun fix(f: SwitchFix, retry: () -> Unit) = when (f) {
        SwitchFix.PAIR -> pair()
        SwitchFix.RETRY -> retry()
        SwitchFix.USB_DEBUGGING -> openDeveloperOptions(context)
    }

    Column(
        Modifier
            .windowInsetsPadding(tabInsets())
            .verticalScroll(scroll)
            .fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp)
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (isPaired) macName else "Passthrough", style = PT.display(30.sp), color = c.primary,
                modifier = Modifier.weight(1f).semantics { heading() }, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            PTCircleIconButton(Icons.Filled.Settings, "Settings", onSettings)
        }

        // A shell waiting on a question comes before everything else.
        if (reach == ShellReach.READY) {
            running.filter { it.isAsking }.forEach { s -> NeedsYouCard(s) { onOpenTerminal(s.id) } }
        }

        if (!isPaired) SetupCard(onPair = pair)
        else StatusCard(reach = reach, path = path, online = online, state = state, redialing = redialing, onRetry = shell::connect)

        PTCard(padding = 6.dp) {
            SwitchRow("Internet through this phone", Icons.Filled.Wifi, internet, onToggle = { onPower() }) { fix(it, onPower) }
            HorizontalDivider(Modifier.padding(start = 62.dp), color = c.cardBorder)
            SwitchRow("Keep Mac awake", Icons.Filled.Coffee, awake, onToggle = { on ->
                lastTapped = MacSwitch.AWAKE
                if (on) shell.control(MacControl.Awake(true))
                else if (running.isNotEmpty()) confirmSleep = true
                else shell.control(MacControl.Awake(false))
            }) { fix(it, shell::connect) }
            HorizontalDivider(Modifier.padding(start = 62.dp), color = c.cardBorder)
            SwitchRow("VPN", Icons.Filled.Shield, vpn, warning = state?.vpn == MacStates.VPN_FAILED, onToggle = { on ->
                lastTapped = MacSwitch.VPN
                if (on) shell.control(MacControl.Vpn(true)) else askVpnOff = true
            }) { fix(it, shell::connect) }
            // Said once for both of the Mac's switches.
            block?.let { Note(it, Modifier.padding(start = 12.dp, end = 12.dp, bottom = 10.dp)) { f -> fix(f, shell::connect) } }
        }

        if (reach == ShellReach.READY) ShellsPreview(sessions, macName, onOpenTerminal, onShells)

        ThisPhoneRow(vm, onThisPhone)
    }

    if (confirmSleep) {
        AlertDialog(
            onDismissRequest = { confirmSleep = false },
            title = { Text("Let $macName sleep?") },
            text = { Text(if (running.size == 1) "1 running shell pauses until it wakes." else "${running.size} running shells pause until it wakes.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmSleep = false
                    shell.control(MacControl.Awake(false))
                }) { Text("Let it sleep") }
            },
            dismissButton = { TextButton(onClick = { confirmSleep = false }) { Text("Cancel") } },
        )
    }
    if (askVpnOff) {
        VpnOffDialog(
            macName = macName,
            killSwitch = state?.killSwitch == true,
            reason = "Lowers protection, so it asks first",
            activity = activity,
            onDismiss = { askVpnOff = false },
            onConfirmed = {
                askVpnOff = false
                shell.control(MacControl.Vpn(false))
            },
        )
    }
}

/**
 * One switch: what it is, how it is right under its title, and the switch.
 * The whole row toggles; a note under it (outside the toggle, so its fix is
 * its own button) says why it can't change, or what to do next.
 */
@Composable
private fun SwitchRow(
    title: String, icon: ImageVector, model: SwitchModel, warning: Boolean = false,
    onToggle: (Boolean) -> Unit, onFix: (SwitchFix) -> Unit,
) {
    val c = LocalPT.current
    val on = model.on
    val fill by animateColorAsState(if (warning) PT.attention else if (on) c.tint else c.fill, tween(250), label = "fill")
    Column {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(RoundedCornerShape(18.dp))
                .toggleable(value = on, enabled = model.enabled, role = Role.Switch, onValueChange = onToggle)
                .semantics { if (model.pending) stateDescription = if (on) "Turning on" else "Turning off" }
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(Modifier.size(36.dp).background(fill, CircleShape), contentAlignment = Alignment.Center) {
                Icon(
                    if (warning) Icons.Filled.Warning else icon, null, modifier = Modifier.size(18.dp),
                    tint = if (warning) PT.onAttention else if (on) PT.onTint else c.primary.copy(alpha = if (model.enabled) 1f else 0.45f),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = PT.display(16.sp, FontWeight.SemiBold), color = c.primary.copy(alpha = if (model.enabled) 1f else 0.6f))
                Text(
                    model.status, style = PT.display(13.sp, FontWeight.Normal),
                    color = if (warning) c.attentionText else if (on && !model.pending) c.tintText else c.secondary,
                )
            }
            if (model.pending) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.secondary)
            // The row carries the toggle for touch and TalkBack.
            Switch(
                checked = on, onCheckedChange = null, enabled = model.enabled,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = c.tint, checkedThumbColor = Color.White, checkedBorderColor = c.tint,
                    disabledCheckedTrackColor = c.tint.copy(alpha = 0.4f), disabledCheckedThumbColor = Color.White.copy(alpha = 0.8f),
                ),
            )
        }
        model.note?.let { Note(it, Modifier.padding(start = 62.dp, end = 12.dp, bottom = 10.dp), onFix) }
    }
}

@Composable
private fun Note(note: SwitchNote, modifier: Modifier = Modifier, onFix: (SwitchFix) -> Unit) {
    val c = LocalPT.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
            Icon(
                if (note.warning) Icons.Filled.Warning else Icons.Filled.Info, null,
                tint = if (note.warning) c.attentionText else c.secondary, modifier = Modifier.padding(top = 2.dp).size(14.dp),
            )
            Text(note.text, style = PT.display(13.sp, FontWeight.Normal), color = if (note.warning) c.attentionText else c.secondary)
        }
        note.fix?.let { f ->
            TextButton(onClick = { onFix(f) }, modifier = Modifier.padding(start = 10.dp).heightIn(min = 48.dp)) {
                Text(f.label, style = PT.display(14.sp, FontWeight.SemiBold), color = c.tintText)
            }
        }
    }
}

/** The first time: pair over USB. Starting to share comes with it. */
@Composable
private fun SetupCard(onPair: () -> Unit) {
    val c = LocalPT.current
    PTCard(padding = 16.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Box(Modifier.size(56.dp).background(c.fill, RoundedCornerShape(16.dp)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Laptop, null, tint = c.secondary, modifier = Modifier.size(30.dp))
                }
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Set up your Mac", style = PT.display(20.sp), color = c.primary)
                    Text("Pair once over USB.", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                }
            }
            PTSteps(listOf(
                "Plug this phone into your Mac with a USB cable.",
                "Open Passthrough in the Mac's menu bar.",
                "Tap Pair your Mac and type the code on the Mac.",
            ))
            PrimaryButton("Pair your Mac", onPair)
        }
    }
}

/** The paired Mac: how it's reached, its battery, and a way back when it can't be reached. */
@Composable
private fun StatusCard(
    reach: ShellReach, path: ShellPath?, online: Boolean, state: MacState?, redialing: Boolean, onRetry: () -> Unit,
) {
    val c = LocalPT.current
    val ready = reach == ShellReach.READY
    val title = when (reach) {
        ShellReach.READY -> "Connected"
        ShellReach.CONNECTING -> if (redialing) "Reconnecting…" else "Connecting…"
        ShellReach.UNREACHABLE -> "Can't reach it"
        ShellReach.NO_ACCESS -> if (online) "Plugged in" else "Paired"
        ShellReach.LOCKED -> "Unlock to continue"
        ShellReach.NEEDS_PASSCODE -> "Set a screen lock"
        ShellReach.KEY_UNAVAILABLE -> "Plug in to renew access"
        ShellReach.UNSUPPORTED -> "Not on this phone"
    }
    val detail = when {
        ready -> when (path) {
            ShellPath.DIRECT -> "From anywhere, directly"
            ShellPath.RELAY -> "From anywhere, through a relay"
            ShellPath.LOCAL -> "On this network"
            else -> null
        }
        reach == ShellReach.NO_ACCESS -> if (online) "Online through this phone over USB" else "Not plugged in"
        else -> null
    }
    val border by animateColorAsState(if (reach == ShellReach.UNREACHABLE) PT.attention.copy(alpha = 0.45f) else c.cardBorder, tween(300), label = "border")
    Column(
        Modifier.fillMaxWidth().background(c.card, RoundedCornerShape(24.dp)).border(1.dp, border, RoundedCornerShape(24.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(56.dp).background(if (ready) c.cardOn else c.fill, RoundedCornerShape(16.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Laptop, null, tint = if (ready) c.tintText else c.secondary, modifier = Modifier.size(30.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = PT.display(20.sp), color = c.primary)
                detail?.let { Text(it, style = PT.display(15.sp, FontWeight.Normal), color = c.secondary) }
            }
        }
        if (ready && state?.battery != null) BatteryLine(state, state.battery, state.awake == true)
        if (reach == ShellReach.UNREACHABLE) {
            Column(
                Modifier.fillMaxWidth().background(PT.attention.copy(alpha = 0.1f), RoundedCornerShape(16.dp)).padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (state?.awakeStopped == MacStates.STOPPED_BATTERY) {
                    Text("It most likely went to sleep", style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
                    Text(
                        "Its battery reached your ${MacFormat.percent(state.batteryFloor ?: 0.2)} limit, so Keep Mac awake let it sleep. Plug it in and it wakes for the next connection.",
                        style = PT.display(14.sp, FontWeight.Normal), color = c.primary,
                    )
                } else {
                    Text("It may be asleep, off, or offline", style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
                    reach.message?.let { Text(it, style = PT.display(14.sp, FontWeight.Normal), color = c.primary) }
                }
            }
            PrimaryButton("Try again", onRetry, Icons.Filled.Refresh)
        }
    }
}

/** One tap in: this phone's sharing, pairing, data used and settings. */
@Composable
private fun ThisPhoneRow(vm: AppViewModel, onClick: () -> Unit) {
    val c = LocalPT.current
    val name by vm.settings.deviceName.collectAsStateWithLifecycle()
    val usage by vm.usage.collectAsStateWithLifecycle()
    val paired by vm.pairedClients.collectAsStateWithLifecycle()
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp)
            .background(c.card, RoundedCornerShape(20.dp)).border(1.dp, c.cardBorder, RoundedCornerShape(20.dp))
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.size(36.dp).background(c.fill, CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PhoneAndroid, null, tint = c.primary, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("This phone", style = PT.display(16.sp, FontWeight.SemiBold), color = c.primary)
            Text(
                "$name · " + (if (paired.size == 1) "1 Mac paired" else "${paired.size} Macs paired") +
                    " · ${ByteFormat.bytes(usage.monthTotal)} this month",
                style = PT.display(13.sp, FontWeight.Normal), color = c.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(Icons.Filled.ChevronRight, null, tint = c.tertiary)
    }
}

@Composable
private fun BatteryLine(state: MacState, battery: Double, awake: Boolean) {
    val c = LocalPT.current
    val caption = when {
        state.charging == true -> "${MacFormat.percent(battery)}, charging"
        !awake -> "${MacFormat.percent(battery)} on battery"
        else -> "${MacFormat.percent(battery)} now · sleeps " + listOfNotNull(state.batteryFloor?.let { "at ${MacFormat.percent(it)}" }, "if it gets hot").joinToString(" or ")
    }
    Column(Modifier.semantics { contentDescription = "Battery ${MacFormat.percent(battery)}. $caption" }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().height(6.dp).background(c.fill, RoundedCornerShape(3.dp))) {
            Box(Modifier.fillMaxWidth(battery.toFloat().coerceIn(0.03f, 1f)).height(6.dp).background(if (awake) c.tint else c.secondary, RoundedCornerShape(3.dp)))
            val floor = state.batteryFloor
            if (floor != null && state.charging != true) {
                Box(Modifier.fillMaxWidth(floor.toFloat()).height(6.dp), contentAlignment = Alignment.CenterEnd) {
                    Box(Modifier.size(width = 2.dp, height = 6.dp).background(c.card))
                }
            }
        }
        Text(caption, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
    }
}

@Composable
private fun NeedsYouCard(session: ShellSessionInfo, onOpen: () -> Unit) {
    val c = LocalPT.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp)
            .background(PT.attention.copy(alpha = 0.1f), RoundedCornerShape(20.dp))
            .border(1.dp, PT.attention.copy(alpha = 0.35f), RoundedCornerShape(20.dp))
            .clickable(role = Role.Button, onClick = onOpen).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(10.dp).background(PT.attention, CircleShape))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("${session.title} is asking", style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(session.waiting ?: "", fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = c.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text("Answer", style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
    }
}

@Composable
private fun ShellsPreview(sessions: List<ShellSessionInfo>, macName: String, onOpen: (String?) -> Unit, onShells: () -> Unit) {
    val c = LocalPT.current
    val now = System.currentTimeMillis() / 1000.0
    PTCard(padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Shells", style = PT.display(17.sp), color = c.primary, modifier = Modifier.weight(1f))
            if (sessions.isNotEmpty()) TextButton(onClick = onShells) { Text("See all", color = c.tintText) }
        }
        if (sessions.isEmpty()) {
            Text("Nothing running. Start a shell to run commands on $macName.", style = PT.display(14.sp, FontWeight.Normal), color = c.secondary)
            Spacer(Modifier.height(10.dp))
            PrimaryButton("New shell", { onOpen(null) }, Icons.Filled.Add)
        } else {
            sessions.sortedWith(compareByDescending<ShellSessionInfo> { it.running }.thenByDescending { it.lastOutputAt }).take(3).forEach { s ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(role = Role.Button) { onOpen(s.id) },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.size(8.dp).background(if (s.isAsking) PT.attention else if (s.running) c.tint else c.tertiary, CircleShape))
                    Column(Modifier.weight(1f)) {
                        Text(s.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(ShellFormat.status(s, now), style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Icon(Icons.Filled.ChevronRight, null, tint = c.tertiary)
                }
            }
            TextButton(onClick = { onOpen(null) }) {
                Icon(Icons.Filled.Add, null, tint = c.tintText, modifier = Modifier.size(18.dp))
                Text(" New shell", color = c.tintText, style = PT.display(15.sp, FontWeight.SemiBold))
            }
        }
    }
}

/** A mint capsule with dark text (white on mint is unreadable). */
@Composable
internal fun PrimaryButton(label: String, onClick: () -> Unit, icon: ImageVector? = null, enabled: Boolean = true) {
    Button(
        onClick = onClick, enabled = enabled,
        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        colors = ButtonDefaults.buttonColors(containerColor = LocalPT.current.tint, contentColor = PT.onTint),
    ) {
        icon?.let { Icon(it, null, modifier = Modifier.size(18.dp).padding(end = 2.dp)) }
        Text(label, style = PT.display(16.sp, FontWeight.SemiBold))
    }
}
