package dev.dpatel.passthrough.service

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import dev.dpatel.passthrough.core.KeyValueStore
import dev.dpatel.passthrough.core.PassthroughProtocol
import dev.dpatel.passthrough.core.ShellConnectMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** User settings, observable from Compose. Same keys as the iOS app's shared defaults. */
class AppSettings(context: Context) {
    val prefs: SharedPreferences = context.getSharedPreferences("passthrough", Context.MODE_PRIVATE)

    private fun defaultName(context: Context): String =
        Settings.Global.getString(context.contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL ?: "Android"

    private val _deviceName = MutableStateFlow(prefs.getString(DEVICE_NAME, null) ?: defaultName(context))
    val deviceName: StateFlow<String> = _deviceName
    private val _cellularOnly = MutableStateFlow(prefs.getBoolean(CELLULAR_ONLY, true))
    val cellularOnly: StateFlow<Boolean> = _cellularOnly
    private val _allowUDP = MutableStateFlow(prefs.getBoolean(ALLOW_UDP, true))
    val allowUDP: StateFlow<Boolean> = _allowUDP
    private val _socksPort = MutableStateFlow(prefs.getInt(SOCKS_PORT, PassthroughProtocol.DEFAULT_SOCKS_PORT))
    val socksPort: StateFlow<Int> = _socksPort
    private val _controlPort = MutableStateFlow(prefs.getInt(CONTROL_PORT, PassthroughProtocol.DEFAULT_CONTROL_PORT))
    val controlPort: StateFlow<Int> = _controlPort
    private val _shellConnectMode = MutableStateFlow(ShellConnectMode.fromStored(prefs.getString(SHELL_CONNECT_MODE, null)))
    /** Remote shell's "Connect using", for this device only. */
    val shellConnectMode: StateFlow<ShellConnectMode> = _shellConnectMode
    private val _captureProtection = MutableStateFlow(prefs.getBoolean(CAPTURE_PROTECTION, true))
    /** "Hide shell and Screen from screenshots and recordings": on unless the user turns it off. */
    val captureProtection: StateFlow<Boolean> = _captureProtection

    fun setDeviceName(v: String) { _deviceName.value = v; prefs.edit().putString(DEVICE_NAME, v).apply() }
    fun setCellularOnly(v: Boolean) { _cellularOnly.value = v; prefs.edit().putBoolean(CELLULAR_ONLY, v).apply() }
    fun setAllowUDP(v: Boolean) { _allowUDP.value = v; prefs.edit().putBoolean(ALLOW_UDP, v).apply() }
    fun setSocksPort(v: Int) { _socksPort.value = v; prefs.edit().putInt(SOCKS_PORT, v).apply() }
    fun setControlPort(v: Int) { _controlPort.value = v; prefs.edit().putInt(CONTROL_PORT, v).apply() }
    fun setShellConnectMode(v: ShellConnectMode) { _shellConnectMode.value = v; prefs.edit().putString(SHELL_CONNECT_MODE, v.stored).apply() }
    fun setCaptureProtection(v: Boolean) { _captureProtection.value = v; prefs.edit().putBoolean(CAPTURE_PROTECTION, v).apply() }

    /** The address the user typed for a Mac's shell, dialed before the ones the Mac sent. */
    fun shellManualAddress(macID: String): String? = prefs.getString(SHELL_MANUAL_ADDRESS + macID, null)

    /** Blank removes it. */
    fun setShellManualAddress(macID: String, address: String) {
        val trimmed = address.trim()
        prefs.edit().apply { if (trimmed.isEmpty()) remove(SHELL_MANUAL_ADDRESS + macID) else putString(SHELL_MANUAL_ADDRESS + macID, trimmed) }.apply()
    }

    fun clearShellManualAddress(macID: String) { prefs.edit().remove(SHELL_MANUAL_ADDRESS + macID).apply() }

    fun clearShellManualAddresses() {
        val keys = prefs.all.keys.filter { it.startsWith(SHELL_MANUAL_ADDRESS) }
        prefs.edit().apply { keys.forEach { remove(it) } }.apply()
    }

    companion object {
        const val DEVICE_NAME = "device.name"
        const val CELLULAR_ONLY = "settings.cellularOnly"
        const val ALLOW_UDP = "settings.allowUDP"
        const val SOCKS_PORT = "settings.socksPort"
        const val CONTROL_PORT = "settings.controlPort"
        /** Same prefix as the iOS app. */
        const val SHELL_MANUAL_ADDRESS = "shell.manualAddress."
        /** Same key and values as the iOS app. */
        const val SHELL_CONNECT_MODE = "shell.connectMode"
        /** Same key as the iOS app. */
        const val CAPTURE_PROTECTION = "captureProtection"
    }
}

/** SharedPreferences-backed store for the pairing registry. */
class PrefsStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = prefs.getString(key, null)
    @android.annotation.SuppressLint("ApplySharedPref")
    override fun putString(key: String, value: String?) {
        // commit(): a pairing must be on disk before the token goes back to the Mac.
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.commit()
    }
}
