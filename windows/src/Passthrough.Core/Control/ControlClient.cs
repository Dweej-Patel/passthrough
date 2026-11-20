using System.Threading.Channels;
using Passthrough.Core.Protocol;

namespace Passthrough.Core.Control;

/// <summary>
/// PC side of the control channel: says hello, proves the pairing (or pairs), keeps a heartbeat, and relays
/// the phone's live status (port of ControlClient.swift).
/// <para>
/// Whatever answers on the phone's port may not be the phone: another phone on the cable, or an app squatting
/// the port on an Android phone. So the token is never sent; the phone must prove it holds the pairing first
/// (<see cref="ControlAuth"/>), and only then does the PC prove itself.
/// </para>
/// <para>
/// Every way the channel ends (the phone closing it, a read or write failure, garbage on the wire, a failed
/// proof, a version mismatch, silence) is reported as exactly one <see cref="ControlEvent.Disconnected"/>, the
/// last event, after which <see cref="Events"/> completes. <see cref="DisposeAsync"/> ends it without one (the
/// owner asked) and completes <see cref="Events"/>. Nothing is thrown from the background reader.
/// </para>
/// </summary>
public sealed class ControlClient(
    Func<CancellationToken, Task<Stream>> open,
    ControlIdentity identity,
    string deviceKind,
    TimeProvider time) : IAsyncDisposable
{
    private readonly Channel<ControlEvent> _events = Channel.CreateUnbounded<ControlEvent>();
    private readonly Channel<ControlEnvelope> _outgoing = Channel.CreateUnbounded<ControlEnvelope>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _stop = new();
    private readonly byte[] _macNonce = ControlAuth.Nonce();

    /// <summary>Guards every field below; events and outgoing messages are queued under it, so their order is the order of decisions.</summary>
    private readonly Lock _gate = new();
    private bool _started;
    private bool _closed;
    private ITimer? _heartbeat;
    private Task _running = Task.CompletedTask;
    private long _lastHeard;
    private bool _welcomed;
    /// <summary>The phone proved the pairing (or paired here).</summary>
    private bool _authenticated;
    /// <summary>A <c>pair</c> is out and unanswered: the one time a <c>paired</c> counts.</summary>
    private bool _pairing;
    /// <summary>A code entered before the phone's welcome; sent once it arrives.</summary>
    private string? _pendingCode;

    public ChannelReader<ControlEvent> Events => _events.Reader;

    /// <summary>
    /// Opens the stream and says hello; the rest runs in the background and is reported through <see cref="Events"/>.
    /// A failure to open is reported as <see cref="ControlEvent.Disconnected"/>, not thrown. Call once.
    /// </summary>
    public async Task StartAsync(CancellationToken ct)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_closed && !_started, this);
            if (_started) throw new InvalidOperationException("The control client is already started");
            _started = true;
        }

        Stream stream;
        try
        {
            stream = await open(ct).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            lock (_gate) Finish(e);
            return;
        }

        var channel = new LineChannel(stream);
        lock (_gate)
        {
            if (!_closed)
            {
                _lastHeard = time.GetTimestamp();
                Send(new ControlEnvelope(ControlEnvelope.Hello)
                {
                    ProtocolVersion = ProtocolConstants.Version,
                    ClientID = identity.ClientId,
                    Name = identity.Name,
                    Nonce = Convert.ToBase64String(_macNonce),
                    Via = "usb",
                });
                _heartbeat = time.CreateTimer(_ => Beat(), null, ProtocolConstants.PingInterval, ProtocolConstants.PingInterval);
                _running = RunAsync(channel);
                return;
            }
        }
        await channel.DisposeAsync().ConfigureAwait(false); // disposed while opening
    }

    /// <summary>Sends the six-digit code shown on the phone; held until the phone's welcome if it comes first.</summary>
    public Task SubmitCodeAsync(string code)
    {
        lock (_gate)
        {
            if (_closed) return Task.CompletedTask;
            if (!_welcomed) _pendingCode = code;
            else SendPair(code);
        }
        return Task.CompletedTask;
    }

    /// <summary>Closes the channel without a <see cref="ControlEvent.Disconnected"/>, completes <see cref="Events"/>, and waits for the background work to end.</summary>
    public async ValueTask DisposeAsync()
    {
        Task running;
        lock (_gate)
        {
            Finish(null, silent: true);
            running = _running;
        }
        await running.ConfigureAwait(false);
    }

    private Task RunAsync(LineChannel channel) => Task.Run(async () =>
    {
        var writing = WriteLoopAsync(channel);
        try
        {
            while (await channel.ReadAsync(_stop.Token).ConfigureAwait(false) is { } m)
            {
                lock (_gate) Handle(m);
            }
            lock (_gate) Finish(null);
        }
        catch (Exception e)
        {
            lock (_gate) Finish(e); // after our own Finish (cancellation, disposal) this does nothing
        }
        finally
        {
            lock (_gate) Finish(null);
            await writing.ConfigureAwait(false);
            try { await channel.DisposeAsync().ConfigureAwait(false); }
            catch (Exception) { } // the connection is already over
        }
    });

    private Task WriteLoopAsync(LineChannel channel) => Task.Run(async () =>
    {
        try
        {
            await foreach (var m in _outgoing.Reader.ReadAllAsync(_stop.Token).ConfigureAwait(false))
                await channel.WriteAsync(m, _stop.Token).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            lock (_gate) Finish(e);
        }
    });

    private void Beat()
    {
        lock (_gate)
        {
            if (_closed) return;
            if (time.GetElapsedTime(_lastHeard) >= ProtocolConstants.SilenceLimit)
            {
                Finish(new TimeoutException("The phone stopped responding"));
                return;
            }
            Send(new ControlEnvelope(ControlEnvelope.Ping));
        }
    }

    /// <summary>One message from the phone. Called under the lock.</summary>
    private void Handle(ControlEnvelope m)
    {
        if (_closed) return;
        _lastHeard = time.GetTimestamp();
        switch (m.T)
        {
            case ControlEnvelope.Welcome:
                if (_welcomed) return;
                _welcomed = true;
                Welcome(m);
                break;
            case ControlEnvelope.Paired:
                // Only the answer to our own pair, once: anything else could plant a token of its choosing.
                if (!_pairing) return;
                _pairing = false;
                if (m.Token is { } token)
                {
                    _authenticated = true;
                    Emit(new ControlEvent.PairedWith(token));
                }
                break;
            case ControlEnvelope.Error:
                var failure = PairingFailureWire.Parse(m.Reason);
                if (failure == PairingFailure.UnsupportedVersion)
                {
                    // Phones from before version 2 say nothing of their own version.
                    Finish(new ControlException(ControlErrorKind.Incompatible, deviceKind,
                        phoneIsOlder: (m.ProtocolVersion ?? 1) < ProtocolConstants.Version));
                    return;
                }
                _pairing = false;
                Emit(new ControlEvent.PairingFailed(failure));
                break;
            case ControlEnvelope.Goodbye:
                if (_authenticated) Emit(new ControlEvent.Goodbye());
                break;
            case ControlEnvelope.Status:
                if (!_authenticated) return;
                var status = new DeviceStatus(m.DeviceName ?? deviceKind, m.Radio, m.Carrier, m.Battery, m.Hosting ?? "", m.Ipv6, m.InternetFrom);
                Emit(new ControlEvent.StatusUpdate(status, m.RxBytes ?? 0, m.TxBytes ?? 0, m.ActiveConnections ?? 0));
                break;
        }
    }

    private void Welcome(ControlEnvelope m)
    {
        var version = m.ProtocolVersion ?? 0;
        if (version != ProtocolConstants.Version)
        {
            Finish(new ControlException(ControlErrorKind.Incompatible, deviceKind, phoneIsOlder: version < ProtocolConstants.Version));
            return;
        }
        // Nothing else in a welcome counts: the phone's status comes only after the proofs.
        // A phone that remembers a pairing this PC has no token for counts as unpaired; pairing again replaces it.
        var paired = false;
        if (m.PairedFlag == true && identity.Token is { } token)
        {
            var key = ControlAuth.Key(token);
            var phoneNonce = ControlAuth.DecodeNonce(m.Nonce);
            if (phoneNonce is null || !ControlAuth.IsValidPhoneProof(m.Proof, key, identity.ClientId, _macNonce, phoneNonce))
            {
                // Said it was paired but could not prove it: send nothing, end the connection.
                Finish(new ControlException(ControlErrorKind.ProofFailed, deviceKind));
                return;
            }
            // Our proof goes before anything else on this channel.
            Send(new ControlEnvelope(ControlEnvelope.Auth)
            {
                Proof = Convert.ToBase64String(ControlAuth.MacProof(key, identity.ClientId, _macNonce, phoneNonce)),
            });
            _authenticated = true;
            paired = true;
        }
        Emit(new ControlEvent.Welcomed(paired));
        if (!paired && _pendingCode is { } code)
        {
            _pendingCode = null;
            SendPair(code);
        }
    }

    private void SendPair(string code)
    {
        _pairing = true;
        Send(new ControlEnvelope(ControlEnvelope.Pair) { ClientID = identity.ClientId, Name = identity.Name, Code = code });
    }

    private void Send(ControlEnvelope m) => _outgoing.Writer.TryWrite(m);

    private void Emit(ControlEvent e)
    {
        if (!_closed) _events.Writer.TryWrite(e);
    }

    /// <summary>Ends the channel once: stops the heartbeat and the background loops, reports why unless <paramref name="silent"/>, and completes <see cref="Events"/>. Called under the lock.</summary>
    private void Finish(Exception? error, bool silent = false)
    {
        if (_closed) return;
        if (!silent) Emit(new ControlEvent.Disconnected(error));
        _closed = true;
        _events.Writer.TryComplete();
        _outgoing.Writer.TryComplete();
        _heartbeat?.Dispose();
        _heartbeat = null;
        _stop.Cancel();
    }
}
