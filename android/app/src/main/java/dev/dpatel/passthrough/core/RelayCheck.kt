package dev.dpatel.passthrough.core

import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Whether a computer's relay answers, asked once after a connect from anywhere failed, so the
 * page can say "the relay isn't answering" rather than "it may be off". Behind an interface so
 * the page's logic is tested without the network. Mirrors RelayCheck in PassthroughCore (Swift).
 */
fun interface RelayCheck {
    suspend fun answers(url: String): Boolean
}

/**
 * A TLS handshake (system trust) with the relay URL's host and port (443 when it names none),
 * within [timeoutMs]. Nothing is sent after the handshake, and the relay's token is never used.
 */
class TlsRelayCheck(private val timeoutMs: Int = 3_000) : RelayCheck {
    override suspend fun answers(url: String): Boolean = withContext(Dispatchers.IO) {
        val uri = runCatching { URI(url) }.getOrNull() ?: return@withContext false
        val host = uri.host ?: return@withContext false
        val port = if (uri.port in 1..65535) uri.port else 443
        runCatching {
            Socket().use { plain ->
                plain.connect(InetSocketAddress(host, port), timeoutMs)
                plain.soTimeout = timeoutMs
                // Layered with the host name, so the handshake names it (SNI). Only liveness is asked: nothing is trusted from it.
                (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(plain, host, port, true).use { tls ->
                    (tls as SSLSocket).startHandshake()
                }
            }
            true
        }.getOrDefault(false)
    }
}
