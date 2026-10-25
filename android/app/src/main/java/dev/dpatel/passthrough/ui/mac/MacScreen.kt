package dev.dpatel.passthrough.ui.mac

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.MacControl
import dev.dpatel.passthrough.core.MacState
import dev.dpatel.passthrough.core.MacStates
import dev.dpatel.passthrough.core.Moment
import dev.dpatel.passthrough.core.ShellError
import dev.dpatel.passthrough.core.ShellPath
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.core.vpnUp
import dev.dpatel.passthrough.service.ServiceState
import dev.dpatel.passthrough.ui.AppViewModel
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.PTCircleIconButton
import dev.dpatel.passthrough.ui.shell.ShellFormat
import dev.dpatel.passthrough.ui.shell.ShellReach
import dev.dpatel.passthrough.ui.shell.ShellViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Mac tab, as on iOS: the Mac and how it's reached, shells waiting on a
 * question, Desk / Away / Public, Internet, Keep awake and the VPN, and its
 * shells. Turning the VPN off asks for the biometric first; turning anything
 * on never asks.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacScreen(
    vm: AppViewModel,
    shell: ShellViewModel,
    onPower: () -> Unit,
    onPair: () -> Unit,
    onSettings: () -> Unit,
    onOpenTerminal: (String?) -> Unit,
    onShells: () -> Unit,
) {
    val c = LocalPT.current
    val activity = LocalContext.current as? FragmentActivity
    val scope = rememberCoroutineScope()
    val service by vm.state.collectAsStateWithLifecycle()
    val stats by vm.stats.collectAsStateWithLifecycle()
    val paired by vm.pairedClients.collectAsStateWithLifecycle()
    val reach by shell.reach.collectAsStateWithLifecycle()
    val macs by shell.macs.collectAsStateWithLifecycle()
    val selected by shell.selectedMacID.collectAsStateWithLifecycle()
    val sessions by shell.sessions.collectAsStateWithLifecycle()
    val path by shell.path.collectAsStateWithLifecycle()
    val state by shell.macState.collectAsStateWithLifecycle()
    val pending by shell.pendingControl.collectAsStateWithLifecycle()
    val controlError by shell.controlError.collectAsStateWithLifecycle()

    val macID = selected ?: paired.firstOrNull()?.id
    val macName = macs.firstOrNull { it.macID == selected }?.macName ?: paired.firstOrNull()?.name ?: "Your Mac"
    val online = macID != null && stats.macs.any { it.id == macID }
    val canControl = reach == ShellReach.READY && state?.control == true
    val internetOn = service.isActive
    val running = sessions.filter { it.running }

    var picked by remember { mutableStateOf<Moment?>(null) }
    var momentNote by remember { mutableStateOf<String?>(null) }
    var confirmSleep by rememberSaveable { mutableStateOf(false) }
    var vpnOffFor by remember { mutableStateOf<Moment?>(null) }
    var askVpnOff by rememberSaveable { mutableStateOf(false) }
    var showStepAway by rememberSaveable { mutableStateOf(false) }

    fun apply(moment: Moment) {
        val target = moment.switches ?: return
        val s = state ?: return
        picked = moment
        if (target.internet != internetOn) onPower()
        if (target.awake != (s.awake == true)) shell.control(MacControl.Awake(target.awake))
        target.vpn?.let { if (it != s.vpnUp) shell.control(MacControl.Vpn(it)) }
        scope.launch { delay(8_000); if (picked == moment) picked = null }
    }

    fun pick(moment: Moment) {
        momentNote = null
        val target = moment.switches ?: return
        val s = state ?: return
        if (target.vpn == true && s.vpn == null) {
            momentNote = "${moment.title} needs a VPN set up on $macName. Add one in Passthrough's VPN settings on the Mac."
            return
        }
        // Lowering protection asks first; raising it never does.
        if (target.vpn == false && s.vpnUp) { vpnOffFor = moment; askVpnOff = true } else apply(moment)
    }

    Column(
        Modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .verticalScroll(rememberScrollState())
            .fillMaxWidth().wrapContentWidth().widthIn(max = 640.dp)
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(macName, style = PT.display(30.sp), color = c.primary, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            PTCircleIconButton(Icons.Filled.Settings, "Settings", onSettings)
        }

        HeroCard(
            paired = paired.isNotEmpty() || macs.isNotEmpty(), reach = reach, path = path, online = online,
            state = state, redialing = shell.redialing.collectAsStateWithLifecycle().value,
            onPair = onPair, onRetry = shell::connect,
        )

        if (reach == ShellReach.READY) {
            running.filter { it.waiting != null }.forEach { s -> NeedsYouCard(s) { onOpenTerminal(s.id) } }
        }

        val s = state
        if (s != null && canControl) {
            val current = Moment.current(internetOn, s.awake == true, s.vpnUp)
            LaunchedEffect(current) { if (current == picked) picked = null }
            val shown = picked ?: current
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    Moment.choices.forEachIndexed { i, m ->
                        SegmentedButton(
                            selected = shown == m, onClick = { pick(m) },
                            shape = SegmentedButtonDefaults.itemShape(i, Moment.choices.size),
                            icon = {},
                        ) { Text(m.title) }
                    }
                }
                Text(momentNote ?: shown.caption, style = PT.display(13.sp, FontWeight.Normal), color = c.secondary, modifier = Modifier.padding(horizontal = 4.dp))
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 56.dp)
                        .background(c.card, RoundedCornerShape(18.dp)).border(1.dp, c.cardBorder, RoundedCornerShape(18.dp))
                        .clickable(role = Role.Button) { showStepAway = true }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.size(32.dp).background(c.tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                        Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, tint = c.tintText, modifier = Modifier.size(18.dp))
                    }
                    Column(Modifier.weight(1f)) {
                        Text("Step away", style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary)
                        Text("Check what would stop it working while you're gone", style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
                    }
                    Icon(Icons.Filled.ChevronRight, null, tint = c.tertiary)
                }
            }
        }

        // Internet, Keep awake, VPN.
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Tile(
                    "Internet", when (service) {
                        ServiceState.Running -> if (online) "Mac online via this phone" else "On, waiting for the Mac"
                        ServiceState.Starting -> "Starting…"
                        ServiceState.Stopping -> "Stopping…"
                        is ServiceState.Failed -> "Couldn't start"
                        ServiceState.Stopped -> "Off"
                    },
                    Icons.Filled.Wifi, on = internetOn, enabled = service != ServiceState.Starting && service != ServiceState.Stopping,
                    modifier = Modifier.weight(1f), onClick = onPower,
                )
                if (s != null) {
                    Tile(
                        "Keep awake", awakeDetail(s), Icons.Filled.Coffee, on = s.awake == true, enabled = canControl,
                        pending = pending is MacControl.Awake, modifier = Modifier.weight(1f),
                    ) {
                        if (s.awake == true) {
                            if (running.isNotEmpty()) confirmSleep = true else shell.control(MacControl.Awake(false))
                        } else shell.control(MacControl.Awake(true))
                    }
                } else Spacer(Modifier.weight(1f))
            }
            if (s != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Tile(
                        "VPN", vpnDetail(s), Icons.Filled.Shield, on = s.vpnUp, enabled = canControl && s.vpn != null,
                        pending = pending is MacControl.Vpn, warning = s.vpn == MacStates.VPN_FAILED, modifier = Modifier.weight(1f),
                    ) {
                        if (s.vpn == MacStates.VPN_OFF) shell.control(MacControl.Vpn(true)) else { vpnOffFor = null; askVpnOff = true }
                    }
                    Spacer(Modifier.weight(1f))
                }
            }
            val note = controlError?.let(::controlMessage)
                ?: if (reach == ShellReach.READY && s != null && s.control != true)
                    "Keep awake and the VPN can be changed from $macName only. To change them from here, turn on Awake & VPN for this phone in Passthrough's Remote Shell settings on the Mac."
                else null
            note?.let { Text(it, style = PT.display(13.sp, FontWeight.Normal), color = c.secondary, modifier = Modifier.padding(horizontal = 4.dp)) }
        }

        if (reach == ShellReach.READY) ShellsPreview(sessions, macName, onOpenTerminal, onShells)
    }

    if (confirmSleep) {
        AlertDialog(
            onDismissRequest = { confirmSleep = false },
            title = { Text("Let $macName sleep?") },
            text = { Text(if (running.size == 1) "1 running shell pauses until it wakes." else "${running.size} running shells pause until it wakes.") },
            confirmButton = { TextButton(onClick = { confirmSleep = false; shell.control(MacControl.Awake(false)) }) { Text("Let it sleep") } },
            dismissButton = { TextButton(onClick = { confirmSleep = false }) { Text("Cancel") } },
        )
    }
    if (askVpnOff) {
        val moment = vpnOffFor
        VpnOffDialog(
            macName = macName,
            killSwitch = state?.killSwitch == true,
            reason = moment?.let { "Switching to ${it.title} turns it off" } ?: "Lowers protection, so it asks first",
            activity = activity,
            onDismiss = { askVpnOff = false; vpnOffFor = null },
            onConfirmed = {
                askVpnOff = false
                if (moment != null) apply(moment) else shell.control(MacControl.Vpn(false))
                vpnOffFor = null
            },
        )
    }
    if (showStepAway) {
        StepAwaySheet(
            shell = shell, macName = macName, online = online, onDismiss = { showStepAway = false },
            onSwitchNow = { if (internetOn) onPower() },
            onStepAway = {
                showStepAway = false
                apply(Moment.AWAY)
                StepAway.markNow(vm.settings.prefs)
            },
        )
    }
}

internal fun controlMessage(error: ShellError): String? = when (error) {
    ShellError.NOT_ALLOWED -> "Your Mac doesn't let this phone change Keep awake and the VPN. Turn on Awake & VPN for it in Passthrough's Remote Shell settings on your Mac."
    ShellError.VPN_NOT_SET_UP -> "Your Mac has no VPN set up yet. Add one in Passthrough's VPN settings on the Mac."
    else -> null
}

/** "3 h 10 m", "45 m". */
internal fun duration(minutes: Int): String = if (minutes >= 60) "${minutes / 60} h ${minutes % 60} m" else "$minutes m"

internal fun percent(fraction: Double): String = "${Math.round(fraction * 100)}%"

private fun awakeDetail(s: MacState): String {
    if (s.awake == true) {
        if (s.charging == true) return "On, plugged in"
        s.minutesLeft?.let { return duration(it) + " left" }
        return "On, even lid closed"
    }
    return when (s.awakeStopped) {
        "battery" -> "Stopped at battery limit"
        "heat" -> "Stopped: running hot"
        else -> "Sleeps as usual"
    }
}

private fun vpnDetail(s: MacState): String = when (s.vpn) {
    MacStates.VPN_ON -> s.vpnName ?: "On"
    MacStates.VPN_CONNECTING -> "Connecting…"
    MacStates.VPN_FAILED -> if (s.killSwitch == true) "Failed, traffic blocked" else "Failed"
    MacStates.VPN_OFF -> "Off"
    else -> "Not set up on the Mac"
}

@Composable
private fun HeroCard(
    paired: Boolean, reach: ShellReach, path: ShellPath?, online: Boolean, state: MacState?, redialing: Boolean,
    onPair: () -> Unit, onRetry: () -> Unit,
) {
    val c = LocalPT.current
    val awake = reach == ShellReach.READY && state?.awake == true
    val title = when {
        !paired -> "Set up your Mac"
        reach == ShellReach.READY -> if (awake) "Staying awake" else "Reachable"
        reach == ShellReach.CONNECTING -> if (redialing) "Reconnecting…" else "Connecting…"
        reach == ShellReach.UNREACHABLE -> "Can't reach it"
        reach == ShellReach.NO_ACCESS -> if (online) "Online through this phone" else "Paired"
        else -> "Needs you"
    }
    val detail = when {
        !paired -> "Pair once over USB."
        reach == ShellReach.READY && awake && state != null ->
            if (state.charging == true) "Plugged in" else state.minutesLeft?.let { duration(it) + " left" } ?: "Even with the lid closed"
        reach == ShellReach.READY -> when (path) {
            ShellPath.DIRECT -> "From anywhere, directly"
            ShellPath.RELAY -> "From anywhere, through a relay"
            ShellPath.LOCAL -> "On this network"
            else -> "Connected"
        }
        reach == ShellReach.NO_ACCESS && online -> "Plugged in over USB"
        else -> null
    }
    val border by animateColorAsState(if (reach == ShellReach.UNREACHABLE) PT.attention.copy(alpha = 0.45f) else c.cardBorder, tween(300), label = "border")
    Column(
        Modifier.fillMaxWidth().background(c.card, RoundedCornerShape(24.dp)).border(1.dp, border, RoundedCornerShape(24.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(
                Modifier.size(64.dp).background(if (awake) c.cardOn else c.fill, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Laptop, null, tint = if (awake || reach == ShellReach.READY) c.tintText else c.secondary, modifier = Modifier.size(34.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = PT.display(20.sp), color = c.primary)
                detail?.let { Text(it, style = PT.display(15.sp, FontWeight.Normal), color = c.secondary) }
                if (online && reach == ShellReach.READY) Text("Online through this phone", style = PT.display(12.sp, FontWeight.SemiBold), color = c.tintText)
            }
        }
        if (paired && reach == ShellReach.READY && state?.battery != null) BatteryLine(state, state.battery!!, awake)
        when {
            !paired -> PrimaryButton("Pair your Mac", onPair)
            reach == ShellReach.UNREACHABLE -> {
                Column(
                    Modifier.fillMaxWidth().background(PT.attention.copy(alpha = 0.1f), RoundedCornerShape(16.dp)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (state?.awakeStopped == "battery") {
                        Text("It most likely went to sleep", style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
                        Text(
                            "Its battery reached your ${percent(state.batteryFloor ?: 0.2)} limit, so Keep awake let it sleep. Plug it in and it wakes for the next connection.",
                            style = PT.display(14.sp, FontWeight.Normal), color = c.primary,
                        )
                    } else {
                        Text("It may be asleep, off, or offline", style = PT.display(14.sp, FontWeight.SemiBold), color = c.attentionText)
                        reach.message?.let { Text(it, style = PT.display(14.sp, FontWeight.Normal), color = c.primary) }
                    }
                }
                PrimaryButton("Try again", onRetry, Icons.Filled.Refresh)
            }
            reach in setOf(ShellReach.LOCKED, ShellReach.NEEDS_PASSCODE, ShellReach.KEY_UNAVAILABLE, ShellReach.UNSUPPORTED) ->
                reach.message?.let { Text(it, style = PT.display(14.sp, FontWeight.Normal), color = c.attentionText) }
            else -> Unit
        }
    }
}

@Composable
private fun BatteryLine(state: MacState, battery: Double, awake: Boolean) {
    val c = LocalPT.current
    val caption = when {
        state.charging == true -> "${percent(battery)}, charging"
        !awake -> "${percent(battery)} on battery"
        else -> "${percent(battery)} now · sleeps " + listOfNotNull(state.batteryFloor?.let { "at ${percent(it)}" }, "if it gets hot").joinToString(" or ")
    }
    Column(Modifier.semantics { contentDescription = "Battery ${percent(battery)}. $caption" }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
private fun Tile(
    title: String, detail: String, icon: ImageVector, on: Boolean, modifier: Modifier = Modifier,
    enabled: Boolean = true, pending: Boolean = false, warning: Boolean = false, onClick: () -> Unit,
) {
    val c = LocalPT.current
    val fill by animateColorAsState(if (on) c.cardOn else c.card, tween(250), label = "fill")
    val shape = RoundedCornerShape(24.dp)
    Column(
        modifier.heightIn(min = 104.dp)
            .background(fill, shape)
            .border(1.dp, if (on) c.tint.copy(alpha = 0.45f) else c.cardBorder, shape)
            .clickable(enabled = enabled, role = Role.Switch, onClick = onClick)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.size(36.dp).background(if (warning) PT.attention else if (on) c.tint else c.fill, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (pending) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = if (on) PT.onTint else c.primary)
            else Icon(
                if (warning) Icons.Filled.Warning else icon, null, modifier = Modifier.size(18.dp),
                tint = if (warning) PT.onAttention else if (on) PT.onTint else c.primary.copy(alpha = if (enabled) 1f else 0.5f),
            )
        }
        Column {
            Text(title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary.copy(alpha = if (enabled) 1f else 0.5f))
            Text(detail, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
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
                    Box(Modifier.size(8.dp).background(if (s.running && s.waiting != null) PT.attention else if (s.running) c.tint else c.tertiary, CircleShape))
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
