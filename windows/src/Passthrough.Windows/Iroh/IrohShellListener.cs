using Passthrough.Core.Shell.Serving;

namespace Passthrough.Windows.Iroh;

/// <summary>
/// The PC's remote-shell door over iroh (a port of IrohShellListener.swift): accepts phones' connections on the shell
/// ALPN from anywhere, direct or through a relay, and hands each to the <see cref="ShellGate"/>, which admits only those
/// that say <c>hello</c> and prove a phone's key. Before the QUIC handshake each attempt needs a handshake slot: 2 per
/// remote IP (or network) on direct paths, 8 shared by attempts through relays, 16 in all, each until its proof or the
/// timeout. Only attempts whose address QUIC has validated get one (the rest are sent a retry first), so packets with
/// forged source addresses can't hold slots.
/// </summary>
public sealed class IrohShellListener : IDisposable
{
    internal const string RelayBucket = "relay";
    internal const int MaxRelayHandshakes = 8;

    private readonly IrohEndpoint _endpoint;
    private readonly ShellGate _gate;
    private readonly Action<string>? _log;
    private Thread? _loop;
    private volatile bool _stopped;

    public IrohShellListener(IrohEndpoint endpoint, ShellGate gate, Action<string>? log = null)
    {
        _endpoint = endpoint;
        _gate = gate;
        _log = log;
    }

    /// <summary>The endpoint stopped accepting underneath the listener (it was closed); it won't accept again.</summary>
    public event Action<Exception?>? Failed;

    public void Start()
    {
        if (_loop is not null || _stopped) return;
        _loop = new Thread(AcceptLoop) { IsBackground = true, Name = "iroh shell accept" };
        _loop.Start();
        _log?.Invoke("iroh: shell listener started");
    }

    /// <summary>Stops accepting and drops every connection; sessions keep running. The endpoint's lifetime stays the caller's.</summary>
    public void Stop()
    {
        _stopped = true;
        _gate.Stop();
    }

    public void Dispose() => Stop();

    /// <summary>The limiter bucket for an attempt: its IP on a direct path (with the per-host cap), else the shared relay bucket.</summary>
    internal static (string Key, int? Max) Bucket(IrohPath path, string? ip) =>
        path == IrohPath.Direct && ip is not null ? (ip, null) : (RelayBucket, MaxRelayHandshakes);

    private void AcceptLoop()
    {
        IrohException? failure = null;
        try
        {
            while (_endpoint.Accept() is { } incoming)
            {
                if (_stopped) { incoming.Cancel(); incoming.Dispose(); break; }
                _ = Task.Run(() => AdmitAsync(incoming));
            }
        }
        catch (IrohException e) { failure = e; }
        if (_stopped) return;
        _log?.Invoke($"iroh: shell listener stopped accepting{(failure is null ? "" : $" ({failure.Code})")}");
        Failed?.Invoke(failure);
    }

    private async Task AdmitAsync(IrohIncoming incoming)
    {
        ShellGate.Admission? admission = null;
        IrohStream? stream = null;
        try
        {
            // A stateless round trip that proves the peer receives at its address.
            if (!incoming.IsAddressValidated)
            {
                if (!incoming.Retry()) incoming.Cancel();
                return;
            }
            var (path, ip) = incoming.Origin();
            var (key, max) = Bucket(path, ip);
            // At the timeout an attempt still in its QUIC handshake is cancelled, so that handshake fails.
            admission = _gate.Admit(key, incoming.Cancel, max);
            if (admission is null)
            {
                _log?.Invoke("iroh: refused a connection: too many unproven handshakes");
                incoming.Cancel();
                return;
            }
            stream = incoming.AcceptStream();
        }
        catch (IrohException)
        {
            if (admission is not null) _gate.Abandon(admission);
            return;
        }
        finally { incoming.Dispose(); }
        await _gate.ServeAsync(admission!, stream!).ConfigureAwait(false);
    }
}
