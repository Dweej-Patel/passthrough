package dev.dpatel.passthrough.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.layout.Box
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
    val withdrawn by vm.pairingCodeWithdrawn.collectAsStateWithLifecycle()
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
                Modifier.fillMaxWidth().statusBarsPadding().navigationBarsPadding().padding(bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                // A grab handle (the sheet opens full height, so there's no scrim to tap) and a way out.
                Box(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                    Box(Modifier.align(Alignment.TopCenter).size(width = 40.dp, height = 5.dp).background(c.tertiary, CircleShape))
                    PTTopBar("", onDone = onDismiss, doneLabel = "Close")
                }
                Icon(
                    Icons.Filled.Devices, null, tint = Color.White,
                    modifier = Modifier.size(58.dp)
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
                    Box(Modifier.padding(horizontal = 24.dp)) {
                        PTNotice("Start the proxy first", PT.warning, Icons.Filled.Warning, detail = "The Mac can only reach this phone while the proxy is on.")
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
                    if (withdrawn) {
                        Box(Modifier.padding(horizontal = 24.dp)) {
                            PTNotice("That code was withdrawn", PT.warning, Icons.Filled.Warning, detail = PAIRING_CODE_WITHDRAWN)
                        }
                    }
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

/** Why the code on screen went away early. Same words as the iPhone app's. */
const val PAIRING_CODE_WITHDRAWN = "Too many wrong codes were entered, so it no longer works. If that wasn't you, something on this phone or the Mac tried to guess it. Generate a new code to pair."
