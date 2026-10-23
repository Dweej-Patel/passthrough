package dev.dpatel.passthrough.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.RemoteShell
import dev.dpatel.passthrough.core.ShellCredentials
import dev.dpatel.passthrough.core.ShellService
import dev.dpatel.passthrough.core.ptLog
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * Browses for Macs advertising the shell (`_passthrough-sh._tcp`) and
 * resolves each, one at a time (older NsdManagers refuse concurrent
 * resolves). Which result belongs to which Mac is
 * [ShellCredentials.discovered]'s call; [endpoint] applies it.
 */
class ShellDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val lock = Any()
    /** By the raw NSD service name. */
    private val found = LinkedHashMap<String, ShellService>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    private val _services = MutableStateFlow<List<ShellService>>(emptyList())
    val services: StateFlow<List<ShellService>> = _services.asStateFlow()

    /** Where to dial [macName] via Bonjour, or null when no result can be tied to it. */
    fun endpoint(macName: String, shellMacCount: Int): Flow<Pair<String, Int>?> =
        services.map { ShellCredentials.discovered(it, macName, shellMacCount)?.endpoint }.distinctUntilChanged()

    fun start() {
        val l = synchronized(lock) {
            if (listener != null || nsd == null) return
            DiscoveryListener().also { listener = it }
        }
        try {
            nsd!!.discoverServices(RemoteShell.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: RuntimeException) {
            ptLog(PtLog.Level.WARNING, "shell: browse failed to start (${e.javaClass.simpleName})")
            synchronized(lock) { if (listener === l) listener = null }
        }
    }

    fun stop() {
        val l = synchronized(lock) {
            val l = listener ?: return
            listener = null
            found.clear()
            resolveQueue.clear()
            publish()
            l
        }
        runCatching { nsd?.stopServiceDiscovery(l) }
    }

    private fun publish() { _services.value = found.values.toList() }

    private fun resolveNext() {
        val info = synchronized(lock) {
            if (resolving || listener == null) return
            val next = resolveQueue.removeFirstOrNull() ?: return
            resolving = true
            next
        }
        try {
            @Suppress("DEPRECATION")
            nsd!!.resolveService(info, ResolveListener())
        } catch (e: RuntimeException) {
            ptLog(PtLog.Level.WARNING, "shell: resolve failed (${e.javaClass.simpleName})")
            synchronized(lock) { resolving = false }
        }
    }

    private inner class DiscoveryListener : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) {
            synchronized(lock) {
                if (listener !== this) return
                found[info.serviceName] = ShellService(ShellCredentials.unescapeServiceName(info.serviceName), null, 0)
                resolveQueue.removeAll { it.serviceName == info.serviceName }
                resolveQueue.addLast(info)
                publish()
            }
            resolveNext()
        }

        override fun onServiceLost(info: NsdServiceInfo) {
            synchronized(lock) {
                if (listener !== this) return
                found.remove(info.serviceName)
                resolveQueue.removeAll { it.serviceName == info.serviceName }
                publish()
            }
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            ptLog(PtLog.Level.WARNING, "shell: browse failed ($errorCode)")
            synchronized(lock) { if (listener === this) listener = null }
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            ptLog(PtLog.Level.WARNING, "shell: browse stop failed ($errorCode)")
        }

        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
    }

    private inner class ResolveListener : NsdManager.ResolveListener {
        override fun onServiceResolved(info: NsdServiceInfo) {
            synchronized(lock) {
                resolving = false
                val host = host(info)
                if (listener != null && found.containsKey(info.serviceName) && host != null) {
                    found[info.serviceName] = ShellService(ShellCredentials.unescapeServiceName(info.serviceName), host, info.port)
                    publish()
                }
            }
            resolveNext()
        }

        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
            synchronized(lock) { resolving = false }
            resolveNext()
        }
    }

    private companion object {
        fun host(info: NsdServiceInfo): String? {
            val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                info.hostAddresses.firstOrNull()
            } else {
                @Suppress("DEPRECATION") info.host
            }
            return address?.hostAddress
        }
    }
}
