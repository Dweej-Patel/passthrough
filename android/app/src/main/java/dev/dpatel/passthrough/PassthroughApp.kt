package dev.dpatel.passthrough

import android.app.Application
import android.util.Log
import dev.dpatel.passthrough.core.PairingRegistry
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.service.AppSettings
import dev.dpatel.passthrough.service.DeviceFacts
import dev.dpatel.passthrough.service.PrefsStore
import dev.dpatel.passthrough.service.Runtime
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
        Runtime.registry = PairingRegistry(PrefsStore(settings.prefs)).also { it.onChange = { Runtime.refreshPairing() } }
        Runtime.usage = UsageLedger(settings.prefs)
        Runtime.facts = DeviceFacts(this)
        Runtime.refreshPairing()
    }

    companion object { const val TAG = "Passthrough" }
}
