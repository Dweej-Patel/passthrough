package dev.dpatel.passthrough.ui.shell

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.ShellSessionInfo
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.PTNotice
import dev.dpatel.passthrough.ui.PTSectionTitle
import dev.dpatel.passthrough.ui.PTStatusDot
import dev.dpatel.passthrough.ui.PTSteps
import kotlinx.coroutines.delay

/** What to do, in order, before a Mac has granted this phone the shell. */
internal val SHELL_SETUP_STEPS = listOf(
    "On your Mac, open Passthrough from the menu bar and turn on Remote shell.",
    "Start the proxy here and plug this phone into the Mac (pair it first if needed). The Mac sends this phone a key.",
    "That's it: your Mac's sessions show up here, over Wi-Fi, Tailscale or from anywhere.",
)

/**
 * The home screen's Remote shell card: the selected Mac's sessions, a New
 * button, and the way into the terminal and history. Before setup it lists
 * the steps; when something is wrong it says what to do next. Styled like
 * the Paired Macs card; copy matches the iPhone app.
 */
@Composable
fun RemoteShellCard(vm: ShellViewModel, onOpen: (String?) -> Unit, onHistory: () -> Unit) {
    val c = LocalPT.current
    val context = LocalContext.current
    val reach by vm.reach.collectAsStateWithLifecycle()
    val macs by vm.macs.collectAsStateWithLifecycle()
    val selected by vm.selectedMacID.collectAsStateWithLifecycle()
    val sessions by vm.sessions.collectAsStateWithLifecycle()
    val lastError by vm.lastError.collectAsStateWithLifecycle()
    val path by vm.path.collectAsStateWithLifecycle()
    val fromAnywhere by vm.triedFromAnywhere.collectAsStateWithLifecycle()
    // Ages are in minutes: refresh twice a minute.
    val nowMillis by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(30_000)
            value = System.currentTimeMillis()
        }
    }
    val macName = macs.firstOrNull { it.macID == selected }?.macName
    PTCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PTSectionTitle("Remote shell", Modifier.weight(1f), icon = Icons.Filled.Terminal)
                if (reach == ShellReach.READY || reach == ShellReach.CONNECTING) {
                    ShellPillButton(onClick = { onOpen(null) }, enabled = reach == ShellReach.READY) {
                        Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(4.dp))
                        Text("New", style = PT.display(13.sp, FontWeight.Bold))
                    }
                }
            }
            // Which Mac, and how it's reached: its own line, so long names and large text fit.
            if (macName != null && (reach == ShellReach.READY || reach == ShellReach.CONNECTING || reach == ShellReach.UNREACHABLE)) {
                MacLine(vm, macName, if (reach == ShellReach.READY) path?.label else null, pickable = macs.size > 1)
            }
            when (reach) {
                ShellReach.CONNECTING -> Row(
                    Modifier.fillMaxWidth().padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = PT.accentEnd, strokeWidth = 2.dp)
                    Text("Connecting to ${macName ?: "your Mac"}…", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                }
                ShellReach.READY -> {
                    if (sessions.isEmpty()) {
                        Text("No sessions open on this Mac. Tap New to start one.", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                    } else {
                        Column {
                            sessions.forEach { SessionRow(vm, it, nowMillis, onOpen) }
                        }
                    }
                    lastError?.message()?.let { PTNotice(it, PT.warning, Icons.Filled.Warning) }
                    HistoryLink(onHistory)
                }
                ShellReach.NO_ACCESS -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("Open your Mac's shell from this phone. To set it up:", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                    PTSteps(SHELL_SETUP_STEPS)
                }
                ShellReach.UNREACHABLE -> PTNotice(
                    if (macName != null) "Can't reach this Mac" else "Can't reach your Mac", PT.warning, Icons.Filled.WifiOff,
                    detail = reach.message(fromAnywhere)?.removePrefix("Can't reach your Mac. "),
                    action = "Try again", onAction = { vm.connect() },
                )
                ShellReach.NEEDS_PASSCODE -> PTNotice(
                    "Screen lock needed", PT.warning, Icons.Filled.Lock,
                    detail = "Remote shell keeps its key behind this phone's screen lock. Set a PIN, pattern or password, then come back.",
                    action = "Open security settings",
                    onAction = { runCatching { context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } },
                )
                ShellReach.KEY_UNAVAILABLE -> PTNotice(
                    "Access needs renewing", PT.warning, Icons.Filled.Key,
                    detail = "This phone's Remote shell key can't be read. Start the proxy and plug into the Mac again to renew access.",
                )
                else -> Text(reach.message(fromAnywhere).orEmpty(), style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
            }
        }
    }
}

@Composable
private fun MacLine(vm: ShellViewModel, macName: String, pathLabel: String?, pickable: Boolean) {
    val c = LocalPT.current
    val macs by vm.macs.collectAsStateWithLifecycle()
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .clip(RoundedCornerShape(10.dp))
                .then(if (pickable) Modifier.clickable(role = Role.DropdownList) { open = true }.heightIn(min = 40.dp) else Modifier)
                .semantics { if (pickable) contentDescription = "Mac: $macName. Choose another Mac" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(macName, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false))
            if (pickable) Icon(Icons.Filled.UnfoldMore, null, tint = c.secondary, modifier = Modifier.size(16.dp))
            pathLabel?.let { Text("· $it", style = PT.display(13.sp, FontWeight.Normal), color = c.secondary, maxLines = 1) }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            macs.forEach { mac ->
                DropdownMenuItem(text = { Text(mac.macName) }, onClick = { open = false; vm.select(mac.macID) })
            }
        }
    }
}

@Composable
private fun HistoryLink(onHistory: () -> Unit) {
    val c = LocalPT.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onHistory, role = Role.Button),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.History, null, tint = PT.accentEnd, modifier = Modifier.size(18.dp))
        Text("Session history", style = PT.display(15.sp, FontWeight.SemiBold), color = PT.accentEnd, modifier = Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = c.tertiary, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun SessionRow(vm: ShellViewModel, session: ShellSessionInfo, nowMillis: Long, onOpen: (String?) -> Unit) {
    val c = LocalPT.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).heightIn(min = 52.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button) { onOpen(session.id) },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PTStatusDot(if (session.running) PT.success else c.secondary.copy(alpha = 0.5f), session.running)
            Column(Modifier.weight(1f).padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(session.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(ShellFormat.status(session, nowMillis / 1000.0), style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
            }
        }
        // An ended session has nothing to end; the Mac keeps it listed for a while.
        if (session.running) Box {
            IconButton(onClick = { menu = true }) {
                Icon(Icons.Filled.MoreHoriz, "Options for ${session.title}", tint = c.secondary)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("End session", color = PT.danger) },
                    leadingIcon = { Icon(Icons.Filled.Close, null, tint = PT.danger) },
                    onClick = { menu = false; vm.close(session.id) },
                )
            }
        } else Spacer(Modifier.size(48.dp))
    }
}

/** The app's small tinted capsule button (as "Pair" on the Paired Macs card). */
@Composable
internal fun ShellPillButton(onClick: () -> Unit, enabled: Boolean = true, content: @Composable () -> Unit) {
    FilledTonalButton(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.filledTonalButtonColors(
            containerColor = PT.accentEnd.copy(alpha = 0.16f), contentColor = PT.accentEnd,
            disabledContainerColor = PT.accentEnd.copy(alpha = 0.07f), disabledContentColor = PT.accentEnd.copy(alpha = 0.4f),
        ),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp),
    ) { content() }
}
