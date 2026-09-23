package dev.dpatel.passthrough.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

/** Radio, carrier, battery and link facts, for the UI and for the Mac's status line. */
class DeviceFacts(appContext: Context) {
    /** Application context only: this object lives for the whole process. */
    private val context: Context = appContext.applicationContext
    private val tm = context.getSystemService(TelephonyManager::class.java)
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val battery = context.getSystemService(BatteryManager::class.java)
    @Volatile private var displayOverride: Int = 0
    @Volatile var onWiFi: Boolean = false
        private set
    private var displayCallbackRegistered = false

    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            onWiFi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        }
        override fun onLost(network: Network) { onWiFi = false }
    }

    init {
        runCatching { cm.registerDefaultNetworkCallback(defaultCallback) }
        registerDisplayInfo()
    }

    val hasPhonePermission: Boolean
        get() = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED

    /** Called again after the permission is granted. */
    fun registerDisplayInfo() {
        if (displayCallbackRegistered || Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !hasPhonePermission) return
        runCatching {
            tm.registerTelephonyCallback(ContextCompat.getMainExecutor(context), object : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
                override fun onDisplayInfoChanged(info: TelephonyDisplayInfo) { displayOverride = info.overrideNetworkType }
            })
            displayCallbackRegistered = true
        }
    }

    /** "5G", "LTE", "3G", "2G" or "Cellular" when the phone won't say (no permission). */
    fun cellularLabel(): String {
        if (!hasPhonePermission) return "Cellular"
        val o = displayOverride
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (o == TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA || o == TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED ||
                o == @Suppress("DEPRECATION") TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE)) return "5G"
        val type = try { tm.dataNetworkType } catch (_: SecurityException) { return "Cellular" }
        return when (type) {
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            TelephonyManager.NETWORK_TYPE_LTE, TelephonyManager.NETWORK_TYPE_IWLAN -> "LTE"
            TelephonyManager.NETWORK_TYPE_HSPA, TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA, TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B, TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3G"
            TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT, TelephonyManager.NETWORK_TYPE_GSM -> "2G"
            else -> "Cellular"
        }
    }

    /** What the Mac's traffic will actually ride on. */
    fun radio(cellularOnly: Boolean, running: Boolean, fallback: Boolean): String = when {
        cellularOnly && running && fallback -> "Wi-Fi (cell down)"
        onWiFi && !cellularOnly -> "Wi-Fi"
        else -> cellularLabel()
    }

    fun carrier(): String? = runCatching { tm.networkOperatorName }.getOrNull()?.takeIf { it.isNotBlank() }

    fun battery(): Double? = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).takeIf { it in 0..100 }?.div(100.0)

    /** The Mac reaches this phone through adb, which needs USB debugging. */
    fun usbDebuggingEnabled(): Boolean =
        runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1 }.getOrDefault(true)
}
