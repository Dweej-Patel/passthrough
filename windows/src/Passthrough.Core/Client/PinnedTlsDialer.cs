using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;

namespace Passthrough.Core.Client;

/// <summary>
/// TLS 1.3 to a computer's shell, accepting exactly the certificate whose SHA-256 is the pin (as WirelessLink.swift):
/// no chain, no name, no revocation; no-delay and keep-alive. Windows' TLS has 1.3 from Windows 11 only.
/// </summary>
public sealed class PinnedTlsDialer : IPinnedTlsDialer
{
    public async Task<IShellStream> ConnectAsync(ShellEndpoint endpoint, string certSha256, CancellationToken cancel)
    {
        var client = new TcpClient(AddressFamily.InterNetworkV6) { NoDelay = true };
        client.Client.DualMode = true;
        try
        {
            await client.ConnectAsync(endpoint.Host, endpoint.Port, cancel).ConfigureAwait(false);
            client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 10);
            var ssl = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = "passthrough",
                EnabledSslProtocols = SslProtocols.Tls13,
                CertificateRevocationCheckMode = System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck,
                // The pin, and nothing else: a certificate whose hash differs is refused before anything is sent.
                RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                    certificate is not null && CryptographicOperations.FixedTimeEquals(
                        System.Text.Encoding.ASCII.GetBytes(Convert.ToHexStringLower(SHA256.HashData(certificate.GetRawCertData()))),
                        System.Text.Encoding.ASCII.GetBytes(certSha256.ToLowerInvariant())),
            }, cancel).ConfigureAwait(false);
            var local = (client.Client.LocalEndPoint as IPEndPoint)?.Address;
            return new Connection(ssl, local is { IsIPv4MappedToIPv6: true } ? local.MapToIPv4() : local, client);
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private sealed class Connection(SslStream ssl, IPAddress? local, TcpClient client) : IShellStream
    {
        public Stream Stream => ssl;
        public IPAddress? LocalAddress => local;

        public async ValueTask DisposeAsync()
        {
            await ssl.DisposeAsync().ConfigureAwait(false);
            client.Dispose();
        }
    }
}
