package dev.dpatel.passthrough.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.dpatel.passthrough.core.ByteFormat
import dev.dpatel.passthrough.core.PassthroughProtocol
import dev.dpatel.passthrough.service.ServiceState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairSheet(vm: AppViewModel, onDismiss: () -> Unit) {
    val c = LocalPT.current
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val code by vm.pairingCode.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val clients by vm.pairedClients.collectAsStateWithLifecycle()
    val now by vm.now.collectAsStateWithLifecycle()
    val initialCount = remember { clients.size }

    LaunchedEffect(Unit) { if (vm.pairingCode.value == null) vm.beginPairing() }
    // A new Mac appeared: pairing worked, close the sheet.
    LaunchedEffect(clients.size) { if (clients.size > initialCount) onDismiss() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = c.background, dragHandle = null) {
        PTBackground(glow = 0.8f) {
            Column(
                Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                Spacer(Modifier.width(40.dp).height(5.dp).padding(top = 10.dp))
                Icon(
                    Icons.Filled.Devices, null, tint = Color.White,
                    modifier = Modifier.padding(top = 24.dp).size(58.dp)
                        .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                        .drawWithContent { drawContent(); drawRect(PT.accent, blendMode = BlendMode.SrcIn) },
                )
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Pair a Mac", style = PT.display(28.sp), color = c.primary)
                    Text("Open Passthrough in the menu bar on your Mac, plug in the cable, and enter this code.",
                        style = PT.display(15.sp, FontWeight.Normal), color = c.secondary, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 24.dp))
                }
                if (state != ServiceState.Running) {
                    PTCard(Modifier.padding(horizontal = 24.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Warning, null, tint = PT.warning, modifier = Modifier.size(16.dp))
                            Text("Start the proxy first so the Mac can reach this phone.", style = PT.display(13.sp, FontWeight.Normal), color = PT.warning)
                        }
                    }
                }
                val current = code
                if (current != null) {
                    PairingCodeTiles(current.code)
                    val remainingMs = maxOf(0L, current.expiry - now)
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        LinearProgressIndicator(
                            progress = { remainingMs.toFloat() / PassthroughProtocol.PAIRING_CODE_LIFETIME_MS },
                            color = PT.accentEnd, trackColor = c.fill, modifier = Modifier.width(220.dp),
                            drawStopIndicator = {},
                        )
                        Text("Expires in ${ByteFormat.duration(remainingMs / 1000)}", style = PT.mono(13.sp), color = c.secondary)
                    }
                } else {
                    Button(onClick = { vm.beginPairing() }, colors = ButtonDefaults.buttonColors(containerColor = PT.accentEnd, contentColor = Color.White)) {
                        Text("Generate a new code", style = PT.display(15.sp, FontWeight.SemiBold))
                    }
                }
                Spacer(Modifier.height(40.dp))
                Text("Codes are single use and only work over USB. Each Mac gets its own key you can revoke at any time.",
                    style = PT.display(12.sp, FontWeight.Normal), color = c.tertiary, textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 30.dp))
            }
        }
    }
}

