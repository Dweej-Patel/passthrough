package dev.dpatel.passthrough.core

import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedTrustManager

/**
 * TLS 1.3 to a Mac whose certificate the phone was told over the cable: the
 * only certificate accepted is the leaf whose SHA-256 equals the pin. The pin
 * replaces CA trust and hostname verification; the default trust store is
 * never consulted. Mirrors WirelessLink.pinnedClientParameters on iOS.
 * Android needs API 29+ for TLS 1.3.
 */
object PinnedTls {
    /** Lowercase hex SHA-256 of a DER certificate: the form a `shellGrant` carries. */
    fun fingerprint(der: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }

    /**
     * Connects and completes the TLS handshake within [timeoutMs] overall.
     * The returned socket has no read timeout. Blocking: call off the main thread.
     * [created] gets the plain socket first, so another thread can abandon the
     * attempt by closing it.
     */
    fun socket(host: String, port: Int, pin: String, timeoutMs: Int = 4000, created: (Socket) -> Unit = {}): SSLSocket {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        val raw = Socket()
        try {
            created(raw)
            raw.tcpNoDelay = true
            raw.keepAlive = true
            raw.connect(InetSocketAddress(host, port), timeoutMs)
            val left = ((deadline - System.nanoTime()) / 1_000_000L).toInt()
            if (left <= 0) throw java.net.SocketTimeoutException("TLS handshake timed out")
            raw.soTimeout = left
            val ssl = context(pin).socketFactory.createSocket(raw, host, port, true) as SSLSocket
            try {
                ssl.enabledProtocols = arrayOf(TLS13)
                ssl.startHandshake()
                ssl.soTimeout = 0
                return ssl
            } catch (e: Throwable) {
                runCatching { ssl.close() }
                throw e
            }
        } catch (e: Throwable) {
            runCatching { raw.close() }
            throw e
        }
    }

    private fun context(pin: String): SSLContext =
        SSLContext.getInstance(TLS13).apply { init(null, arrayOf(PinTrustManager(pin)), null) }

    private const val TLS13 = "TLSv1.3"

    /**
     * Extended so the platform uses it as is (a plain X509TrustManager gets
     * wrapped with extra checks); no endpoint identification is configured.
     * Custom on purpose: the pin is the whole trust decision, and it fails closed.
     */
    @android.annotation.SuppressLint("CustomX509TrustManager")
    private class PinTrustManager(private val pin: String) : X509ExtendedTrustManager() {
        private fun check(chain: Array<out X509Certificate>?) {
            val leaf = chain?.firstOrNull() ?: throw CertificateException("no certificate")
            if (!MessageDigest.isEqual(fingerprint(leaf.encoded).toByteArray(), pin.toByteArray())) {
                throw CertificateException("certificate is not the pinned one")
            }
        }

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = check(chain)
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = check(chain)

        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?): Unit = throw CertificateException("client role unsupported")
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?): Unit = throw CertificateException("client role unsupported")
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?): Unit = throw CertificateException("client role unsupported")

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
