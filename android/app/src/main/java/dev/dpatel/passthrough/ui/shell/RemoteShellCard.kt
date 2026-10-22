package dev.dpatel.passthrough.ui.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import dev.dpatel.passthrough.ui.PTSectionTitle
import dev.dpatel.passthrough.ui.PTStatusDot
import kotlinx.coroutines.delay

/**
 * The home screen's Remote shell card: the selected Mac's sessions, a New
 * button, and the way into the terminal and history. Styled like the Paired
 * Macs card; copy matches the iPhone app.
 */
@Composable
fun RemoteShellCard(vm: ShellViewModel, onOpen: (String?) -> Unit, onHistory: () -> Unit) {
    val c = LocalPT.current
    val reach by vm.reach.collectAsStateWithLifecycle()
    val macs by vm.macs.collectAsStateWithLifecycle()
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
    PTCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PTSectionTitle("Remote shell", icon = Icons.Filled.Terminal)
                if (macs.size > 1) MacPicker(vm)
                if (reach == ShellReach.READY) path?.label?.let {
                    Text(it, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, maxLines = 1)
                }
                Spacer(Modifier.weight(1f))
                ShellPillButton(onClick = { onOpen(null) }, enabled = reach == ShellReach.READY) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.size(4.dp))
                    Text("New", style = PT.display(12.sp, FontWeight.Bold))
                }
            }
            when (reach) {
                ShellReach.CONNECTING -> Box(Modifier.fillMaxWidth().padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(22.dp), color = c.secondary, strokeWidth = 2.dp)
                }
                ShellReach.READY -> {
                    if (sessions.isEmpty()) {
                        Text("No open sessions. Tap New to start one.", style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
                    } else {
                        sessions.forEach { SessionRow(vm, it, nowMillis, onOpen) }
                    }
                    lastError?.message()?.let { Text(it, style = PT.display(13.sp, FontWeight.Normal), color = PT.warning) }
                    Row(
                        Modifier.clickable(onClick = onHistory).padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text("History", style = PT.display(12.sp, FontWeight.SemiBold), color = PT.accentEnd)
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = PT.accentEnd, modifier = Modifier.size(16.dp))
                    }
                }
                else -> Text(reach.message(fromAnywhere).orEmpty(), style = PT.display(15.sp, FontWeight.Normal), color = c.secondary)
            }
        }
    }
}

@Composable
private fun MacPicker(vm: ShellViewModel) {
    val c = LocalPT.current
    val macs by vm.macs.collectAsStateWithLifecycle()
    val selected by vm.selectedMacID.collectAsStateWithLifecycle()
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clickable { open = true }.padding(vertical = 4.dp).semantics { contentDescription = "Choose Mac" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(macs.firstOrNull { it.macID == selected }?.macName ?: "Mac", style = PT.display(12.sp, FontWeight.SemiBold), color = c.secondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 120.dp))
            Icon(Icons.Filled.UnfoldMore, null, tint = c.secondary, modifier = Modifier.size(14.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            macs.forEach { mac ->
                DropdownMenuItem(text = { Text(mac.macName) }, onClick = { open = false; vm.select(mac.macID) })
            }
        }
    }
}

@Composable
private fun SessionRow(vm: ShellViewModel, session: ShellSessionInfo, nowMillis: Long, onOpen: (String?) -> Unit) {
    val c = LocalPT.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            Modifier.weight(1f).clickable { onOpen(session.id) },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PTStatusDot(if (session.running) PT.success else c.secondary.copy(alpha = 0.5f), session.running)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(session.title, style = PT.display(15.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(ShellFormat.status(session, nowMillis / 1000.0), style = PT.display(12.sp, FontWeight.Normal), color = c.secondary)
            }
        }
        Box {
            Icon(Icons.Filled.MoreHoriz, "Options for ${session.title}", tint = c.secondary,
                modifier = Modifier.size(28.dp).clickable { menu = true }.padding(2.dp))
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("End session", color = PT.danger) },
                    leadingIcon = { Icon(Icons.Filled.Close, null, tint = PT.danger) },
                    onClick = { menu = false; vm.close(session.id) },
                )
            }
        }
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
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
    ) { content() }
}
