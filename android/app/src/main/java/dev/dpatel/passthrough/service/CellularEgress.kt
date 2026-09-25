package dev.dpatel.passthrough.service

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import dev.dpatel.passthrough.core.DefaultEgress
import dev.dpatel.passthrough.core.Egress
import dev.dpatel.passthrough.core.EgressProvider
import dev.dpatel.passthrough.core.PtLog
import dev.dpatel.passthrough.core.ptLog
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetAddress
import java.net.Socket

/** Sockets and DNS pinned to one Android network. */
class NetworkEgress(private val network: Network, private val cm: ConnectivityManager) : Egress {
    override fun resolve(host: String): List<InetAddress> = network.getAllByName(host).toList()
    override fun bind(socket: Socket) = network.bindSocket(socket)
    override fun bind(socket: DatagramSocket) = network.bindSocket(socket)
    override val label = "cellular"
    override fun dnsServers(): List<InetAddress> = cm.getLinkProperties(network)?.dnsServers.orEmpty()
    override fun hasIPv6(): Boolean? = cm.getLinkProperties(network)?.routesIPv6()
}

/** A default IPv6 route and a global (not link-local or ULA) IPv6 address. */
internal fun LinkProperties.routesIPv6(): Boolean =
    routes.any { it.isDefaultRoute && it.destination.address is Inet6Address } &&
        linkAddresses.any { val a = it.address; a is Inet6Address && !a.isLinkLocalAddress && (a.address[0].toInt() and 0xfe) != 0xfc }

/** Whatever network Android picks (Wi-Fi when it is up), with that network's DNS servers. */
class SystemEgress(context: Context) : Egress by DefaultEgress, EgressProvider {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    override fun dnsServers(): List<InetAddress> = cm.activeNetwork?.let { cm.getLinkProperties(it)?.dnsServers }.orEmpty()
    override fun hasIPv6(): Boolean? = cm.activeNetwork?.let { cm.getLinkProperties(it)?.routesIPv6() }
    override fun acquire(timeoutMs: Long): Egress = this
}

/**
 * "Cellular only": asks Android to bring up (and keep up) mobile data even
 * while Wi-Fi is connected, and pins every outbound socket to it. When
 * cellular has been unusable for [graceMs] (no signal, data switched off),
 * new connections fall back to whatever network the phone has until it
 * returns; brief handoff blips never push traffic onto Wi-Fi.
 */
class CellularEgressProvider(
    private val context: Context,
    private val graceMs: Long = 10_000,
    private val onUsableChange: (Boolean) -> Unit,
) : EgressProvider {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val lock = Object()
    private var network: Network? = null
    private var fallback = false
    private var registered = false

    private val fallbackRunnable = Runnable { setFallback(true) }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(n: Network) {
            synchronized(lock) { network = n; lock.notifyAll() }
            handler.removeCallbacks(fallbackRunnable)
            setFallback(false)
        }
        override fun onLost(n: Network) {
            synchronized(lock) { if (network == n) network = null }
            handler.removeCallbacks(fallbackRunnable)
            handler.postDelayed(fallbackRunnable, graceMs)
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cm.requestNetwork(request, callback)
        registered = true
        // No SIM or mobile data off: the request is simply never satisfied.
        handler.postDelayed(fallbackRunnable, graceMs)
    }

    fun stop() {
        handler.removeCallbacks(fallbackRunnable)
        if (registered) runCatching { cm.unregisterNetworkCallback(callback) }
        registered = false
        synchronized(lock) { network = null; lock.notifyAll() }
    }

    val isFallback: Boolean get() = synchronized(lock) { fallback }

    private fun setFallback(value: Boolean) {
        val changed = synchronized(lock) {
            val c = fallback != value
            fallback = value
            lock.notifyAll()
            c
        }
        if (!changed) return
        if (value) ptLog(PtLog.Level.WARNING, "Cellular data has been unusable for ${graceMs / 1000}s; new connections use any available network until it is back")
        else ptLog(PtLog.Level.INFO, "Cellular data is usable again; new connections use cellular")
        onUsableChange(!value)
    }

    override fun acquire(timeoutMs: Long): Egress? {
        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(lock) {
            while (true) {
                network?.let { return NetworkEgress(it, cm) }
                if (fallback) return SystemEgress(context)
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) return null
                lock.wait(left)
            }
        }
    }
}
