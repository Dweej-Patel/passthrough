package dev.dpatel.passthrough.ui.mac

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.PairedClient
import dev.dpatel.passthrough.core.isAsking
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT
import dev.dpatel.passthrough.ui.PTCard
import dev.dpatel.passthrough.ui.shell.MacProfiles
import dev.dpatel.passthrough.ui.shell.MacStatus
import dev.dpatel.passthrough.ui.shell.ShellViewModel
import kotlinx.coroutines.launch

/**
 * A Mac's profile picture: its initial on a color picked from its ID, with an
 * amber dot when it needs you. It carries no
 * description of its own: the button or row around it says it.
 */
@Composable
fun MacAvatar(macID: String, name: String, modifier: Modifier = Modifier, badge: Boolean = false, size: Dp = 30.dp) {
    val c = LocalPT.current
    val palette = PT.avatarPalette
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size).background(palette[MacProfiles.colorIndex(macID, palette.size)], CircleShape), contentAlignment = Alignment.Center) {
            Text(MacProfiles.initial(name), style = PT.display((size.value * 0.5f).sp, FontWeight.SemiBold), color = Color.White, maxLines = 1)
        }
        if (badge) {
            Box(
                Modifier.align(Alignment.TopEnd).offset(x = size * 0.1f, y = -size * 0.1f)
                    .size(size * 0.4f).background(PT.warning, CircleShape).border(2.dp, c.background, CircleShape),
            )
        }
    }
}

/** The Mac tab's top-trailing button: the avatar of the Mac showing, opening "Your Macs". */
@Composable
fun MacAvatarButton(macID: String, name: String, badge: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).clickable(role = Role.Button, onClick = onClick).semantics {
            contentDescription = "Your Macs"
            stateDescription = if (badge) "$name, another Mac needs you" else name
        },
        contentAlignment = Alignment.Center,
    ) { MacAvatar(macID, name, badge = badge) }
}

/**
 * "Your Macs": every paired Mac with what it's doing, then Add a Mac and
 * Settings. Those two, and an asking row's terminal, are handed to the host
 * only once the sheet has finished closing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacSwitcherSheet(
    shell: ShellViewModel,
    paired: List<PairedClient>,
    onDismiss: () -> Unit,
    onAddMac: () -> Unit,
    onSettings: () -> Unit,
    onOpenTerminal: (String) -> Unit,
) {
    val c = LocalPT.current
    val sheet = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()
    // Rows re-read their status as the live list, the watch and the connection change.
    val macs by shell.macs.collectAsStateWithLifecycle()
    val selected by shell.selectedMacID.collectAsStateWithLifecycle()
    val sessions by shell.visibleSessions.collectAsStateWithLifecycle()
    val watched by shell.watchedMacs.collectAsStateWithLifecycle()
    // Read now (not through a delegate) so a connection change redraws the current Mac's row.
    shell.reach.collectAsStateWithLifecycle().value

    // The first tap wins: rows and actions do nothing while the sheet is closing.
    var acting by remember { mutableStateOf(false) }

    /** Closes the sheet, then [then] (which may present something else). */
    fun close(then: () -> Unit = {}) {
        acting = true
        scope.launch {
            sheet.hide()
            onDismiss()
            then()
        }
    }

    /** The session waiting on a question on that Mac: the live list for this one, what the watch last saw for the others. */
    fun askingSession(macID: String): String? =
        (if (macID == selected) sessions else watched[macID]?.sessions.orEmpty()).firstOrNull { it.isAsking }?.id

    val nowMillis = System.currentTimeMillis()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = c.background) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                .padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Your Macs", style = PT.display(20.sp), color = c.primary,
                modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp).semantics { heading() },
            )
            PTCard(padding = 6.dp) {
                paired.forEachIndexed { index, client ->
                    if (index > 0) HorizontalDivider(Modifier.padding(start = 62.dp), color = c.cardBorder)
                    val name = macs.firstOrNull { it.macID == client.id }?.macName ?: client.name
                    val status = shell.status(client.id)
                    val current = client.id == selected
                    val asking = status is MacStatus.Asking
                    MacRow(
                        macID = client.id, name = name, status = MacProfiles.statusText(status, nowMillis),
                        asking = asking, current = current,
                    ) {
                        if (acting) return@MacRow
                        // The session is read before the switch swaps the lists; the terminal opens after the sheet is gone.
                        val question = if (asking) askingSession(client.id) else null
                        shell.select(client.id)
                        val target = client.id
                        // Only if that Mac is still the one selected once the sheet is gone.
                        close { if (shell.selectedMacID.value == target) question?.let(onOpenTerminal) }
                    }
                }
            }
            PTCard(padding = 6.dp) {
                ActionRow("Add a Mac", Icons.Filled.Add) { if (!acting) close(onAddMac) }
                HorizontalDivider(Modifier.padding(start = 62.dp), color = c.cardBorder)
                ActionRow("Settings", Icons.Filled.Settings) { if (!acting) close(onSettings) }
            }
        }
    }
}

@Composable
private fun MacRow(macID: String, name: String, status: String, asking: Boolean, current: Boolean, onClick: () -> Unit) {
    val c = LocalPT.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp)
            .selectable(selected = current, role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.clearAndSetSemantics {}) { MacAvatar(macID, name, size = 38.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, style = PT.display(16.sp, FontWeight.SemiBold), color = c.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                status, style = PT.display(13.sp, FontWeight.Normal),
                color = if (asking) c.attentionText else c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (current) Icon(Icons.Filled.Check, null, tint = c.tintText, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun ActionRow(title: String, icon: ImageVector, onClick: () -> Unit) {
    val c = LocalPT.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(38.dp), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = c.secondary, modifier = Modifier.size(22.dp))
        }
        Text(title, style = PT.display(16.sp, FontWeight.Normal), color = c.primary)
    }
}
