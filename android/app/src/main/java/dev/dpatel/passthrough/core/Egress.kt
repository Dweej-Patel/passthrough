package dev.dpatel.passthrough.core

import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket

/** Where outbound connections leave the phone: name resolution and socket binding. */
interface Egress {
    fun resolve(host: String): List<InetAddress>
    fun bind(socket: Socket)
    fun bind(socket: DatagramSocket)
    val label: String
    /** The network's own DNS servers, for [DnsRedirect]; empty when unknown. */
    fun dnsServers(): List<InetAddress> = emptyList()
    /** Whether this network routes IPv6; null when unknown. */
    fun hasIPv6(): Boolean? = null
}

/** Hands out the egress to use for a new connection, possibly waiting for one. */
fun interface EgressProvider {
    /** Returns null when no usable network appeared within [timeoutMs]. */
    fun acquire(timeoutMs: Long): Egress?
}

/** The process default network, whatever the OS picks (Wi-Fi when it is up). */
object DefaultEgress : Egress, EgressProvider {
    override fun resolve(host: String): List<InetAddress> = InetAddress.getAllByName(host).toList()
    override fun bind(socket: Socket) {}
    override fun bind(socket: DatagramSocket) {}
    override val label = "default"
    override fun acquire(timeoutMs: Long): Egress = this
}
