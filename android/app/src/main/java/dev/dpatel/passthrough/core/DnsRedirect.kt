package dev.dpatel.passthrough.core

import java.net.InetAddress

/**
 * DNS the Mac aims at a private address (typically its Wi-Fi router, which
 * Tailscale or DHCP left as the resolver) can never be answered through the
 * phone. Instead of refusing it, the phone forwards the query unchanged to its
 * own network's DNS server, falling back to [FALLBACK] when it knows none.
 * Replies go back under the address the Mac asked. Mirrors DNSRedirect.swift.
 */
object DnsRedirect {
    const val PORT = 53
    const val FALLBACK = "1.1.1.1"

    /** A DNS query to a private/local IP address, which would otherwise be refused. */
    fun applies(address: Socks5.Address): Boolean = address.port == PORT && address.ip != null && address.isLocalOnly

    /** The first real server the phone's network provides, else [FALLBACK]. */
    fun server(system: List<InetAddress>): InetAddress =
        system.firstOrNull { !it.isLoopbackAddress && !it.isAnyLocalAddress } ?: InetAddress.getByName(FALLBACK)
}
