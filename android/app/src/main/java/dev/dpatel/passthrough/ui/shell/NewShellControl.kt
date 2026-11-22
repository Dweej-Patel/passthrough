package dev.dpatel.passthrough.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dpatel.passthrough.core.HostShell
import dev.dpatel.passthrough.ui.LocalPT
import dev.dpatel.passthrough.ui.PT

/**
 * New shell when the computer offers more than one: one pill in two parts. The leading part
 * opens [preferred] (the last chosen, else the computer's default), named beside "New"; the
 * trailing arrow lists every shell. TalkBack reaches each shell from the leading part's actions
 * too. [onOpen] gets the shell's id (null: the computer's own choice). A computer with one shell
 * or none listed keeps the plain New button.
 */
@Composable
fun NewShellControl(shells: List<HostShell>, preferred: HostShell?, hostName: String, enabled: Boolean, onOpen: (String?) -> Unit) {
    val c = LocalPT.current
    var menu by remember { mutableStateOf(false) }
    val tint = PT.accentEnd.copy(alpha = if (enabled) 1f else 0.4f)
    Box {
        Row(
            Modifier.clip(CircleShape).background(PT.accentEnd.copy(alpha = if (enabled) 0.16f else 0.07f), CircleShape),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier
                    .minimumInteractiveComponentSize()
                    .clickable(enabled = enabled, role = Role.Button) { onOpen(preferred?.id) }
                    .semantics(mergeDescendants = true) {
                        contentDescription = "New shell"
                        preferred?.let { stateDescription = it.name }
                        customActions = shells.map { s -> CustomAccessibilityAction("New ${s.name} shell") { onOpen(s.id); true } }
                    }
                    .padding(start = 14.dp, end = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Add, null, tint = tint, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(4.dp))
                Text("New", style = PT.display(13.sp, FontWeight.Bold), color = tint)
                preferred?.let {
                    Text(
                        " ${it.name}", style = PT.display(13.sp, FontWeight.Normal), color = c.secondary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 140.dp),
                    )
                }
            }
            Box(Modifier.width(1.dp).height(20.dp).background(tint.copy(alpha = 0.3f)))
            IconButton(
                onClick = { menu = true }, enabled = enabled,
                modifier = Modifier.semantics { stateDescription = "${shells.size} shells on $hostName" },
            ) {
                Icon(Icons.Filled.ArrowDropDown, "Choose a shell", tint = tint)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            shells.forEach { s ->
                val chosen = s.id == preferred?.id
                DropdownMenuItem(
                    text = { Text(s.name) },
                    onClick = { menu = false; onOpen(s.id) },
                    leadingIcon = { if (chosen) Icon(Icons.Filled.Check, null) else Spacer(Modifier.size(24.dp)) },
                    modifier = Modifier.semantics { selected = chosen },
                )
            }
            HorizontalDivider(color = c.cardBorder)
            Text(
                "Shells open as you, never as administrator.",
                style = PT.display(13.sp, FontWeight.Normal), color = c.secondary,
                modifier = Modifier.widthIn(max = 280.dp).padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}
