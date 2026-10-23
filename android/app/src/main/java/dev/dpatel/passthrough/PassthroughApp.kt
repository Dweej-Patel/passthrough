package dev.dpatel.passthrough

import android.app.Application
import android.util.Log
import computer.iroh.IrohAndroid
import dev.dpatel.passthrough.core.IrohAvailability
import dev.dpatel.passthrough.core.PairingRegistry
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.service.AppSettings
import dev.dpatel.passthrough.service.DeviceFacts
import dev.dpatel.passthrough.service.KeystoreSecrets
import dev.dpatel.passthrough.service.PrefsStore
import dev.dpatel.passthrough.service.Runtime
import dev.dpatel.passthrough.service.ShellKeyVault
import dev.dpatel.passthrough.service.UsageLedger
import java.io.File

class PassthroughApp : Application() {
    override fun onCreate() {
        super.onCreate()
        PtLog.platformSink = { level, message ->
            when (level) {
                PtLog.Level.DEBUG -> Log.d(TAG, message)
                PtLog.Level.INFO -> Log.i(TAG, message)
                PtLog.Level.WARNING -> Log.w(TAG, message)
                PtLog.Level.ERROR -> Log.e(TAG, message)
            }
        }
        PtLog.attachFile(File(filesDir, "passthrough.log"))
        val settings = AppSettings(this)
        Runtime.settings = settings
        Runtime.registry = PairingRegistry(PrefsStore(settings.prefs), secrets = KeystoreSecrets(this)).also { it.onChange = { Runtime.refreshPairing() } }
        Runtime.usage = UsageLedger(settings.prefs)
        Runtime.shellVault = ShellKeyVault(this)
        Runtime.facts = DeviceFacts(this)
        // Not loaded here: a native library that fails to load must never stop the app. The shell
        // loads it off the main thread before its first iroh endpoint (iroh's DNS resolver needs the
        // app context), and dials local and Tailscale addresses only if that fails.
        Runtime.iroh = IrohAvailability { IrohAndroid.installAndroidContext(applicationContext) }
        Runtime.refreshPairing()
    }

    companion object { const val TAG = "Passthrough" }
}
