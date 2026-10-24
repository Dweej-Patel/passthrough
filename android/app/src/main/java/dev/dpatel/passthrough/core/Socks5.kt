package dev.dpatel.passthrough.core

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/** SOCKS5 wire helpers shared by the server and tests. */
object Socks5 {
    const val VERSION = 5
    object Method { const val NONE = 0; const val PASSWORD = 2; const val UNACCEPTABLE = 0xFF }
    /** FORWARD_UDP is the "UDP in TCP" extension hev-socks5-tunnel speaks. */
    object Command { const val CONNECT = 1; const val BIND = 2; const val UDP_ASSOCIATE = 3; const val FORWARD_UDP = 5 }
    object AddressType { const val IPV4 = 1; const val DOMAIN = 3; const val IPV6 = 4 }
    object Reply {
        const val SUCCEEDED = 0; const val GENERAL_FAILURE = 1; const val NOT_ALLOWED = 2; const val NETWORK_UNREACHABLE = 3
        const val HOST_UNREACHABLE = 4; const val CONNECTION_REFUSED = 5; const val TTL_EXPIRED = 6
        const val COMMAND_NOT_SUPPORTED = 7; const val ADDRESS_TYPE_NOT_SUPPORTED = 8
    }

    fun reply(code: Int): ByteArray = byteArrayOf(VERSION.toByte(), code.toByte(), 0, AddressType.IPV4.toByte(), 0, 0, 0, 0, 0, 0)

    /** Frames a datagram for "UDP in TCP": [len:2 BE][hdrlen:1][address][payload]. */
    fun frameDatagram(address: ByteArray, payload: ByteArray, length: Int = payload.size): ByteArray {
        val out = ByteArray(3 + address.size + length)
        out[0] = (length shr 8).toByte()
        out[1] = (length and 0xFF).toByte()
        out[2] = (3 + address.size).toByte()
        System.arraycopy(address, 0, out, 3, address.size)
        System.arraycopy(payload, 0, out, 3 + address.size, length)
        return out
    }

    /** Encodes an IP endpoint as ATYP + ADDR + PORT. */
    fun rawAddress(address: InetAddress, port: Int): ByteArray {
        val ip = address.address
        val atyp = if (ip.size == 4) AddressType.IPV4 else AddressType.IPV6
        return byteArrayOf(atyp.toByte()) + ip + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte())
    }

    /** A parsed SOCKS5 address (ATYP + ADDR + PORT) keeping its raw bytes so it can be echoed verbatim. */
    class Address private constructor(
        /** Literal IP when the client sent one; null for domain names. */
        val ip: InetAddress?,
        val host: String,
        val port: Int,
        val raw: ByteArray,
    ) {
        override fun toString() = if (ip is Inet6Address) "[$host]:$port" else "$host:$port"
        override fun equals(other: Any?) = other is Address && other.raw.contentEquals(raw)
        override fun hashCode() = raw.contentHashCode()

        /**
         * Private, loopback, link-local or multicast: never reachable through the
         * phone's uplink, so refuse up front instead of waiting on the radio.
         * A name only counts when it is local by its spelling; what a name
         * resolves to goes through [isLocalIp] before the phone connects.
         */
        val isLocalOnly: Boolean
            get() {
                val a = ip ?: run {
                    val h = host.lowercase().removeSuffix(".")   // "localhost." is localhost too
                    return h == "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".home.arpa") || h.endsWith(".internal")
                }
                return isLocalIp(a)
            }

        companion object {
            /** Whether an address (sent by the Mac, or a name's DNS answer) is a local-only destination. */
            fun isLocalIp(a: InetAddress): Boolean {
                val b = a.address.map { it.toInt() and 0xFF }
                if (b.size == 4) return isLocalV4(b)
                if (b[0] == 0xfe && (b[1] and 0xc0) == 0x80) return true      // fe80::/10
                if ((b[0] and 0xfe) == 0xfc) return true                        // fc00::/7
                if (b[0] == 0xff) return true                                   // multicast
                if (b.all { it == 0 }) return true                              // ::
                if (b.dropLast(1).all { it == 0 } && b.last() == 1) return true // ::1
                // IPv4-mapped, IPv4-compatible and the well-known NAT64 prefix
                // (64:ff9b::/96): classify the embedded v4. NAT64 is how an
                // IPv6-only carrier reaches IPv4 sites, so it can't be blocked whole.
                val mapped = b.subList(0, 10).all { it == 0 } && b[10] == 0xff && b[11] == 0xff
                val compat = b.subList(0, 12).all { it == 0 }
                val nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b.subList(4, 12).all { it == 0 }
                if (mapped || compat || nat64) return isLocalV4(b.subList(12, 16))
                // 64:ff9b:1::/48, the local-use NAT64 prefix: translated on this network, not the uplink.
                if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4] == 0x00 && b[5] == 0x01) return true
                if (b[0] == 0x20 && b[1] == 0x02) return true                   // 2002::/16 (6to4)
                return false
            }

            fun isLocalV4(b: List<Int>): Boolean {
                if (b.size != 4) return false
                if (b[0] == 10 || b[0] == 127 || b[0] == 0) return true   // 0.0.0.0/8 too
                if (b[0] == 172 && b[1] in 16..31) return true
                if (b[0] == 192 && b[1] == 168) return true
                if (b[0] == 192 && b[1] == 0 && b[2] == 0) return true     // 192.0.0.0/24 (IETF protocol assignments)
                if (b[0] == 198 && b[1] in 18..19) return true             // 198.18.0.0/15 (benchmarking)
                if (b[0] == 169 && b[1] == 254) return true
                if (b[0] == 100 && b[1] in 64..127) return true   // CGNAT space
                return b[0] >= 224
            }

            /**
             * An IP address written as a name: `[::1]`, `127.0.0.1`, and the
             * shorthand the system resolver also accepts (`127.1`, `2130706433`,
             * `0x7f.0.0.1`, octal `012.0.0.1`), which would otherwise pass as an
             * ordinary name. Never touches DNS.
             */
            fun ipLiteral(name: String): InetAddress? {
                var n = name
                if (n.startsWith("[") && n.endsWith("]")) n = n.substring(1, n.length - 1)
                if (':' in n) return parseIPv6(n)   // only IPv6 literals contain ':'
                n = n.removeSuffix(".")
                val parts = n.split('.')
                if (n.isEmpty() || n[0] !in '0'..'9' || parts.size > 4) return null
                val values = parts.map { parseInetAtonPart(it) ?: return null }
                // inet_aton: the last part fills every byte the earlier ones left.
                val last = values.last()
                val lastBytes = 4 - (values.size - 1)
                if (values.dropLast(1).any { it > 0xFF } || last >= (1L shl (8 * lastBytes))) return null
                val bytes = ByteArray(4)
                values.dropLast(1).forEachIndexed { i, v -> bytes[i] = v.toByte() }
                for (i in 0 until lastBytes) bytes[3 - i] = (last shr (8 * i)).toByte()
                return Inet4Address.getByAddress(bytes)
            }

            /**
             * A textual IPv6 address (`::`, an embedded dotted IPv4 at the end,
             * a `%scope` ignored), parsed here because InetAddress.getByName
             * falls back to a DNS lookup on Android when it isn't one.
             */
            private fun parseIPv6(text: String): InetAddress? {
                val s = text.substringBefore('%')
                if (s.count { it == ':' } < 2) return null
                val halves = s.split("::")
                if (halves.size > 2 || (halves.size == 2 && '.' in halves[0])) return null
                fun groups(part: String): List<Int>? {
                    if (part.isEmpty()) return emptyList()
                    val pieces = part.split(':')
                    val out = ArrayList<Int>()
                    for ((i, p) in pieces.withIndex()) {
                        if (i == pieces.lastIndex && '.' in p) {
                            val v4 = p.split('.').takeIf { it.size == 4 }
                                ?.map { d -> d.takeIf { it.length in 1..3 && it.all { c -> c in '0'..'9' } }?.toInt()?.takeIf { it <= 255 } ?: return null }
                                ?: return null
                            out += (v4[0] shl 8) or v4[1]; out += (v4[2] shl 8) or v4[3]
                        } else {
                            if (p.length !in 1..4 || !p.all { it in '0'..'9' || it.lowercaseChar() in 'a'..'f' }) return null
                            out += p.toInt(16)
                        }
                    }
                    return out
                }
                val head = groups(halves[0]) ?: return null
                val all = if (halves.size == 2) {
                    val tail = groups(halves[1]) ?: return null
                    if (head.size + tail.size > 7) return null
                    head + List(8 - head.size - tail.size) { 0 } + tail
                } else head
                if (all.size != 8) return null
                val bytes = ByteArray(16)
                all.forEachIndexed { i, g -> bytes[2 * i] = (g shr 8).toByte(); bytes[2 * i + 1] = g.toByte() }
                return InetAddress.getByAddress(bytes)
            }

            /** One dotted part as inet_aton reads it: 0x hex, leading-0 octal, else decimal. */
            private fun parseInetAtonPart(p: String): Long? {
                if (p.isEmpty()) return null
                val (digits, radix) = when {
                    p.startsWith("0x") || p.startsWith("0X") -> p.substring(2) to 16
                    p.length > 1 && p.startsWith("0") -> p.substring(1) to 8
                    else -> p to 10
                }
                val ascii = digits.all { it in '0'..'9' || (radix == 16 && it.lowercaseChar() in 'a'..'f') }
                if (digits.isEmpty() || digits.length > 11 || !ascii) return null
                return digits.toLongOrNull(radix)?.takeIf { it <= 0xFFFFFFFFL }
            }

            fun parse(raw: ByteArray): Address? {
                if (raw.isEmpty()) return null
                val body = raw.copyOfRange(1, raw.size)
                val port = if (raw.size >= 3) ((raw[raw.size - 2].toInt() and 0xFF) shl 8) or (raw[raw.size - 1].toInt() and 0xFF) else return null
                return when (raw[0].toInt()) {
                    AddressType.IPV4 -> {
                        if (body.size != 6) return null
                        val a = Inet4Address.getByAddress(body.copyOfRange(0, 4))
                        Address(a, a.hostAddress ?: "", port, raw)
                    }
                    AddressType.IPV6 -> {
                        if (body.size != 18) return null
                        val a = InetAddress.getByAddress(body.copyOfRange(0, 16))
                        Address(a, a.hostAddress ?: "", port, raw)
                    }
                    AddressType.DOMAIN -> {
                        val len = body.firstOrNull()?.toInt()?.and(0xFF) ?: return null
                        if (body.size != len + 3 || len == 0) return null
                        val name = String(body, 1, len, Charsets.UTF_8)
                        // "10.0.0.1" sent as a name is that IP: classify (and redirect DNS) by it.
                        val literal = ipLiteral(name)
                        if (literal != null) Address(literal, literal.hostAddress ?: name, port, raw) else Address(null, name, port, raw)
                    }
                    else -> null
                }
            }

            fun domain(name: String, port: Int): ByteArray {
                val n = name.toByteArray(Charsets.UTF_8)
                return byteArrayOf(AddressType.DOMAIN.toByte(), n.size.toByte()) + n + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte())
            }

            fun ipv4(bytes: ByteArray, port: Int): ByteArray =
                byteArrayOf(AddressType.IPV4.toByte()) + bytes + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte())
        }
    }
}
