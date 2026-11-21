using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32;
using Passthrough.Core.Screen;
using Passthrough.Core.Shell.Identity;

namespace Passthrough.Windows.Screen;

/// <summary>
/// The relay's view of this PC's Remote Desktop, in the service (stage 5 plan, section 4): whether it may relay now,
/// the dial to <c>127.0.0.1</c> with its far end checked, and the certificate the viewer must see.
/// </summary>
public sealed class RemoteDesktopGate(Func<RemoteDesktopSetup?> setup, Func<string?, bool> workAccount, Action<string>? log = null,
    Func<RemoteDesktopFacts>? probe = null, Func<int?>? termService = null) : IRemoteDesktopGate
{
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(2);
    private readonly Func<RemoteDesktopFacts> _probe = probe ?? RemoteDesktopProbe.Read;
    private readonly Func<int?> _termService = termService ?? RemoteDesktopProbe.TermServiceProcess;
    private readonly Lock _lock = new();
    private (RemoteDesktopFacts Facts, DateTime At)? _facts;

    /// <summary>The facts, at most 2 s old.</summary>
    public RemoteDesktopFacts Facts()
    {
        lock (_lock)
        {
            if (_facts is { } cached && DateTime.UtcNow - cached.At < MaxAge) return cached.Facts;
        }
        var facts = _probe();
        lock (_lock) _facts = (facts, DateTime.UtcNow);
        return facts;
    }

    /// <summary>The verdict for a phone of <paramref name="account"/> (null: the PC's own row).</summary>
    public RemoteDesktopVerdict Verdict(string? account) => RemoteDesktopVerdict.From(Facts(), setup(), account, workAccount(account));

    public Task<RelayVerdict> CheckAsync(string? account, CancellationToken cancel) => Task.Run(() =>
    {
        var verdict = Verdict(account);
        return verdict.IsReady ? RelayVerdict.Ready(Facts().Port) : RelayVerdict.No(verdict.Rdp == RemoteDesktopVerdict.PolicyOff ? RemoteDesktopVerdict.Off : verdict.Rdp);
    }, cancel);

    public async Task<Stream?> DialAsync(int port, CancellationToken cancel)
    {
        var client = new TcpClient(AddressFamily.InterNetwork) { NoDelay = true };
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, port, cancel).ConfigureAwait(false);
            if (!await IsRemoteDesktopAsync(client.Client, port).ConfigureAwait(false))
            {
                log?.Invoke("screen: what answers on Remote Desktop's port is not Remote Desktop");
                client.Dispose();
                return null;
            }
            return client.GetStream();
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException or IOException)
        {
            client.Dispose();
            return null;
        }
    }

    /// <summary>
    /// The far end of this connection belongs to TermService's process: the TCP table's row whose local end is
    /// <c>127.0.0.1:port</c> and remote end is our socket, its owner equal to the service's process id. Looked for up to
    /// three times, 50 ms apart. No process is opened.
    /// </summary>
    private async Task<bool> IsRemoteDesktopAsync(Socket socket, int port)
    {
        if (_termService() is not { } expected) return false;
        var local = (IPEndPoint)socket.LocalEndPoint!;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (Cable.CablePeerCheck.OwnerOf(new IPEndPoint(IPAddress.Loopback, port), local) is { } owner) return owner == expected;
            await Task.Delay(50).ConfigureAwait(false);
        }
        return false;
    }

    public async Task<string?> CertificateSha256Async(CancellationToken cancel)
    {
        if (StoreCertificate() is { } stored) return stored;
        // Not one clear certificate in the store (none, or Windows is renewing): ask Remote Desktop itself.
        return await PresentedAsync(cancel).ConfigureAwait(false);
    }

    /// <summary>The configured certificate (its SHA-1 in RDP-Tcp, from LocalMachine\My), or the one valid certificate in LocalMachine\Remote Desktop.</summary>
    private static string? StoreCertificate()
    {
        try
        {
            using var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var rdpTcp = hklm.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp");
            if (rdpTcp?.GetValue("SSLCertificateSHA1Hash") is byte[] { Length: 20 } thumbprint)
            {
                using var my = new X509Store(StoreName.My, StoreLocation.LocalMachine);
                my.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
                var found = my.Certificates.Find(X509FindType.FindByThumbprint, Convert.ToHexString(thumbprint), validOnly: false);
                return found.Count == 1 ? CertificateDer.Pin(found[0].RawData) : null;
            }
            using var store = new X509Store("Remote Desktop", StoreLocation.LocalMachine);
            store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
            var now = DateTime.Now;
            var valid = store.Certificates.Where(c => c.NotBefore <= now && c.NotAfter >= now).ToList();
            return valid.Count == 1 ? CertificateDer.Pin(valid[0].RawData) : null;
        }
        catch (Exception e) when (e is System.Security.Cryptography.CryptographicException or System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    /// <summary>
    /// The certificate Remote Desktop presents: an X.224 request for TLS on loopback (owner-checked like the relay's
    /// dial), a TLS handshake that only reads the certificate, then closed.
    /// </summary>
    private async Task<string?> PresentedAsync(CancellationToken cancel)
    {
        var port = Facts().Port;
        using var client = new TcpClient(AddressFamily.InterNetwork);
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, port, cancel).ConfigureAwait(false);
            if (!await IsRemoteDesktopAsync(client.Client, port).ConfigureAwait(false)) return null;
            var stream = client.GetStream();
            // TPKT, X.224 connection request, RDP negotiation request: TLS only.
            byte[] request = [0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00];
            await stream.WriteAsync(request, cancel).ConfigureAwait(false);
            var reply = new byte[19];
            await stream.ReadExactlyAsync(reply, cancel).ConfigureAwait(false);
            if (reply[11] != 0x02) return null; // not a negotiation response
            string? pin = null;
            using var ssl = new SslStream(stream, leaveInnerStreamOpen: false, (_, certificate, _, _) =>
            {
                if (certificate is not null) pin = CertificateDer.Pin(certificate.GetRawCertData());
                return true; // read only; nothing is sent over it
            });
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "localhost", EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 }, cancel)
                .ConfigureAwait(false);
            return pin;
        }
        catch (Exception e) when (e is SocketException or IOException or AuthenticationException or OperationCanceledException)
        {
            return null;
        }
    }
}
