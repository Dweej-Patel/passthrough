package dev.dpatel.passthrough.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.core.content.ContextCompat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun SettingsScreen(vm: AppViewModel, onDone: () -> Unit) {
    val c = LocalPT.current
    val s = vm.settings
    val state by vm.state.collectAsStateWithLifecycle()
    val name by s.deviceName.collectAsStateWithLifecycle()
    val cellularOnly by s.cellularOnly.collectAsStateWithLifecycle()
    val allowUDP by s.allowUDP.collectAsStateWithLifecycle()
    val socksPort by s.socksPort.collectAsStateWithLifecycle()
    val controlPort by s.controlPort.collectAsStateWithLifecycle()
    val log by vm.log.collectAsStateWithLifecycle()
    val locked = state.isActive
    var showLog by rememberSaveable { mutableStateOf(false) }
    var showDebug by rememberSaveable { mutableStateOf(false) }
    var confirmForget by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var phoneGranted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED)
    }
    val phonePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        phoneGranted = granted
        if (granted) vm.phonePermissionGranted()
    }
    val version = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "" }

    Box(Modifier.fillMaxSize().background(c.background)) {
        Column(Modifier.windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
                Text("Settings", style = PT.display(17.sp, FontWeight.SemiBold), color = c.primary, modifier = Modifier.align(Alignment.Center))
                Text("Done", style = PT.display(17.sp, FontWeight.Bold), color = PT.accentEnd,
                    modifier = Modifier.align(Alignment.CenterEnd).clickable(onClick = onDone).padding(4.dp))
            }
            Column(
                Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(22.dp),
            ) {
                Section("This phone") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp)) {
                        BasicTextField(
                            value = name, onValueChange = { s.setDeviceName(it.take(64)) }, singleLine = true,
                            textStyle = PT.display(16.sp, FontWeight.Normal).copy(color = c.primary),
                            cursorBrush = SolidColor(PT.accentEnd), modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (name.isEmpty()) Text("Name shown on the Mac", style = PT.display(16.sp, FontWeight.Normal), color = c.tertiary)
                                inner()
                            },
                        )
                    }
                }
                Section(
                    "How the proxy runs",
                    footer = "Passthrough runs as a foreground service with a notification, so it keeps serving with the screen off. It routes none of this phone's own traffic, and it listens on this phone's loopback address only.",
                ) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp)) {
                        Text("Hosting", style = PT.display(16.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
                        Text("Background service", style = PT.display(16.sp, FontWeight.Normal), color = c.secondary)
                    }
                }
                Section(
                    "Network",
                    footer = "On: the Mac always uses cellular data, even when this phone is on Wi-Fi. Off: the Mac rides whatever this phone is using. Changes apply the next time you start the proxy.",
                ) {
                    ToggleRow("Cellular only", cellularOnly, enabled = !locked) { s.setCellularOnly(it) }
                    Divider()
                    ToggleRow("Forward UDP (DNS, QUIC, calls)", allowUDP, enabled = !locked) { s.setAllowUDP(it) }
                }
                Section(
                    null,
                    footer = "Optional. Android files the network type (5G, LTE) under its phone permission, which it describes as making and managing calls. Passthrough only reads the network type; without it the label says Cellular.",
                ) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("Show 5G / LTE", style = PT.display(16.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
                        if (phoneGranted) {
                            Text("On", style = PT.display(16.sp, FontWeight.Normal), color = c.secondary)
                        } else {
                            Text("Allow", style = PT.display(16.sp, FontWeight.SemiBold), color = PT.accentEnd,
                                modifier = Modifier.clickable { phonePermission.launch(Manifest.permission.READ_PHONE_STATE) }.padding(4.dp))
                        }
                    }
                }
                Section("Advanced") {
                    PortRow("SOCKS port", socksPort, enabled = !locked) { s.setSocksPort(it) }
                    Divider()
                    PortRow("Control port", controlPort, enabled = !locked) { s.setControlPort(it) }
                    Divider()
                    Text("Forget all paired Macs", style = PT.display(16.sp, FontWeight.Normal), color = PT.danger,
                        modifier = Modifier.fillMaxWidth().alpha(if (locked) 0.4f else 1f)
                            .clickable(enabled = !locked) { confirmForget = true }.padding(horizontal = 16.dp, vertical = 14.dp))
                }
                Section("Diagnostics") {
                    val rot by animateFloatAsState(if (showLog) 90f else 0f, label = "chevron")
                    Row(Modifier.fillMaxWidth().clickable { showLog = !showLog }.padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("Log", style = PT.display(16.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
                        Icon(Icons.Filled.ChevronRight, null, tint = c.tertiary, modifier = Modifier.rotate(rot))
                    }
                    AnimatedVisibility(showLog) {
                        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (log.isEmpty()) {
                                Text("Nothing logged yet. Start the proxy and connect a Mac; messages appear here.",
                                    style = PT.display(13.sp, FontWeight.Normal), color = c.secondary)
                            } else {
                                LogList(log, showDebug, Modifier.fillMaxWidth().height(260.dp))
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Show debug detail", style = PT.display(15.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
                                PTSwitch(showDebug, true) { showDebug = it }
                            }
                            Row {
                                val fmt = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }
                                Text("Copy log", style = PT.display(15.sp, FontWeight.SemiBold), color = PT.accentEnd,
                                    modifier = Modifier.clickable {
                                        clipboard.setText(AnnotatedString(log.joinToString("\n") { "${fmt.format(Date(it.date))} ${it.level.name.lowercase()} ${it.message}" }))
                                    }.padding(vertical = 4.dp))
                                Box(Modifier.weight(1f))
                                Text("Clear", style = PT.display(15.sp, FontWeight.SemiBold), color = PT.danger,
                                    modifier = Modifier.clickable { vm.clearLog() }.padding(vertical = 4.dp))
                            }
                        }
                    }
                }
                Section(null) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Passthrough $version", style = PT.display(13.sp, FontWeight.SemiBold), color = c.primary)
                        Text("The Mac connects through adb, Android's USB debugging bridge, which needs USB debugging turned on. This app listens on loopback only, so nothing is reachable over Wi-Fi or cellular. Every Mac authenticates with a per-device key that only its own keychain holds.",
                            style = PT.display(13.sp, FontWeight.Normal), color = c.secondary)
                    }
                }
            }
        }
    }
    if (confirmForget) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmForget = false },
            title = { Text("Forget all paired Macs?") },
            text = { Text("Every Mac will need a new pairing code to connect again.") },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { vm.revokeAll(); confirmForget = false }) { Text("Forget all", color = PT.danger) } },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { confirmForget = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Section(header: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val c = LocalPT.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (header != null) Text(header.uppercase(), style = PT.display(12.sp, FontWeight.Normal).copy(letterSpacing = 0.4.sp), color = c.secondary,
            modifier = Modifier.padding(start = 16.dp))
        Column(Modifier.fillMaxWidth().background(c.card, RoundedCornerShape(12.dp)), content = content)
        if (footer != null) Text(footer, style = PT.display(12.sp, FontWeight.Normal), color = c.secondary, modifier = Modifier.padding(horizontal = 16.dp))
    }
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(start = 16.dp), thickness = 0.5.dp, color = LocalPT.current.tertiary)

@Composable
private fun PTSwitch(checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) = Switch(
    checked, onChange, enabled = enabled,
    colors = SwitchDefaults.colors(
        checkedTrackColor = PT.success, checkedThumbColor = androidx.compose.ui.graphics.Color.White, checkedBorderColor = PT.success,
        disabledCheckedTrackColor = PT.success.copy(alpha = 0.45f), disabledCheckedThumbColor = androidx.compose.ui.graphics.Color.White,
        disabledCheckedBorderColor = PT.success.copy(alpha = 0.0f),
    ),
)

@Composable
private fun ToggleRow(title: String, value: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val c = LocalPT.current
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).alpha(if (enabled) 1f else 0.5f), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = PT.display(16.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
        PTSwitch(value, enabled, onChange)
    }
}

@Composable
private fun PortRow(title: String, value: Int, enabled: Boolean, onChange: (Int) -> Unit) {
    val c = LocalPT.current
    var text by remember(value) { mutableStateOf(value.toString()) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp).alpha(if (enabled) 1f else 0.5f), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = PT.display(16.sp, FontWeight.Normal), color = c.primary, modifier = Modifier.weight(1f))
        BasicTextField(
            value = text, enabled = enabled, singleLine = true,
            onValueChange = { v ->
                text = v.filter { it.isDigit() }.take(5)
                text.toIntOrNull()?.takeIf { it in 1024..65535 }?.let(onChange)
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            textStyle = PT.mono(16.sp).copy(color = c.secondary, textAlign = TextAlign.End),
            cursorBrush = SolidColor(PT.accentEnd), modifier = Modifier.width(90.dp),
        )
    }
}

