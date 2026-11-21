using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;

namespace Passthrough.Windows.Net;

/// <summary>
/// The PC's shell door on the same network and Tailscale (stage 4 plan, section 7; a port of ShellListener's accept
/// path): TLS 1.3 only on port 7893. For each connection, before any stream or TLS object exists: the peer must be in
/// the address policy, must have arrived on its own network (an overlay peer on an overlay address), and must get a
/// handshake slot. Only then the TLS handshake, within the slot's time, and the gate's challenge.
/// </summary>
public sealed class TlsListener : IDisposable
{
    private readonly ShellGate _gate;
    private readonly ServiceIdentity _identity;
    private readonly LocalAdapters _adapters;
    private readonly int _port;
    private readonly Action<string>? _log;
    private readonly CancellationTokenSource _stop = new();
    private readonly Dictionary<string, DateTime> _lastLogged = [];
    private Socket? _socket;

    public TlsListener(ShellGate gate, ServiceIdentity identity, LocalAdapters adapters, int port = RemoteShell.DefaultPort, Action<string>? log = null)
    {
        _gate = gate;
        _identity = identity;
        _adapters = adapters;
        _port = port;
        _log = log;
    }

    /// <summary>The port it listens on (the one asked for, or the one chosen when 0 was asked for: tests).</summary>
    public int Port { get; private set; }

    /// <summary>Binds <c>[::]:port</c>, dual-mode, exclusively (no other program can bind a more specific address on it). Throws <see cref="SocketException"/> when the port is taken.</summary>
    public void Start()
    {
        var socket = new Socket(AddressFamily.InterNetworkV6, SocketType.Stream, ProtocolType.Tcp) { DualMode = true, ExclusiveAddressUse = true };
        try
        {
            socket.Bind(new IPEndPoint(IPAddress.IPv6Any, _port));
            socket.Listen(64);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
        _socket = socket;
        Port = ((IPEndPoint)socket.LocalEndPoint!).Port;
        _ = Task.Run(AcceptLoopAsync);
        _log?.Invoke($"tls: listening on port {Port}");
    }

    private async Task AcceptLoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            Socket client;
            try { client = await _socket!.AcceptAsync(_stop.Token).ConfigureAwait(false); }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException) { return; }
            catch (SocketException) { continue; }
            Accept(client);
        }
    }

    /// <summary>The checks, in order, before anything TLS exists for this connection.</summary>
    private void Accept(Socket client)
    {
        string host;
        string? local = null;
        try
        {
            host = Unwrap((IPEndPoint)client.RemoteEndPoint!);
            try { local = Unwrap((IPEndPoint)client.LocalEndPoint!); } catch (SocketException) { }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException) { Refuse(client, "unreadable"); return; }
        var facts = _adapters.Facts;
        var addresses = AdapterPolicy.LocalAddresses(facts);
        if (!ShellAddressPolicy.IsAllowedPeer(host, () => addresses, () => AdapterPolicy.OnLinkPrefixes(facts))) { Refuse(client, "outside the allowed ranges"); return; }
        if (!ShellAddressPolicy.ArrivedOnItsNetwork(host, local, () => addresses)) { Refuse(client, "arrived on another network"); return; }
        if (_gate.Admit(host, () => client.Dispose()) is not { } admission) { Refuse(client, "no handshake slot"); return; }
        client.NoDelay = true;
        client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 10);
        _ = Task.Run(() => HandshakeAsync(client, admission));
    }

    private async Task HandshakeAsync(Socket client, ShellGate.Admission admission)
    {
        var ssl = new SslStream(new NetworkStream(client, ownsSocket: true), leaveInnerStreamOpen: false);
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await ssl.AuthenticateAsServerAsync(Options(), limit.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is AuthenticationException or IOException or OperationCanceledException or ObjectDisposedException or System.ComponentModel.Win32Exception)
        {
            _gate.Abandon(admission);
            await ssl.DisposeAsync().ConfigureAwait(false);
            return;
        }
        // Over TLS there is no hello: the challenge comes first (ShellListener.swift).
        // A computer's signature is bound to this certificate's hash (stage 7 a.1).
        await _gate.ServeAsync(admission, ssl, expectHello: false,
            new Passthrough.Core.Shell.Access.ProofBinding(Passthrough.Core.Shell.Access.ComputerProof.PathTls, Convert.FromHexString(_identity.Pin))).ConfigureAwait(false);
    }

    private SslServerAuthenticationOptions Options() => new()
    {
        ServerCertificateContext = SslStreamCertificateContext.Create(_identity.Certificate, additionalCertificates: null, offline: true),
        EnabledSslProtocols = SslProtocols.Tls13,
        ClientCertificateRequired = false,
        AllowRenegotiation = false,
        CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
        EncryptionPolicy = EncryptionPolicy.RequireEncryption,
    };

    private static string Unwrap(IPEndPoint end)
    {
        var address = end.Address.IsIPv4MappedToIPv6 ? end.Address.MapToIPv4() : end.Address;
        return address.ToString();
    }

    /// <summary>Closed with no linger; logged without the address, once a minute per reason at most.</summary>
    private void Refuse(Socket client, string why)
    {
        try { client.LingerState = new LingerOption(true, 0); } catch (SocketException) { }
        client.Dispose();
        lock (_lastLogged)
        {
            if (_lastLogged.TryGetValue(why, out var at) && DateTime.UtcNow - at < TimeSpan.FromMinutes(1)) return;
            _lastLogged[why] = DateTime.UtcNow;
        }
        _log?.Invoke($"tls: refused a connection ({why})");
    }

    public void Dispose()
    {
        _stop.Cancel();
        _socket?.Dispose();
    }
}
