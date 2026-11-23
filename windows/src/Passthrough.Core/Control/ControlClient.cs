using System.Text;
using System.Threading.Channels;
using Passthrough.Core.Cable;
using Passthrough.Core.Protocol;
using Passthrough.Core.Shell.Access;

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
/// last event, after which <see cref="Events"/> completes; <see cref="DisposeAsync"/> ends it with
/// <c>Disconnected(null)</c>. Nothing is thrown from the background reader.
/// </para>
/// <para>
/// <paramref name="inspect"/> is the cable peer check: it is shown the opened stream before anything is sent and
/// says who holds its far end (<see cref="PeerVerdict"/>). Only a <see cref="PeerVerdict.Genuine"/> channel may carry
/// a shell grant; without a check, none does.
/// </para>
/// </summary>
public sealed class ControlClient(
    Func<CancellationToken, Task<Stream>> open,
    ControlIdentity identity,
    string deviceKind,
    TimeProvider time,
    Func<Stream, PeerVerdict>? inspect = null) : IAsyncDisposable
{
    /// <summary>What this host says it is in <c>hello</c> and its grants.</summary>
    public const string HostKind = "windows";

    private readonly Channel<ControlEvent> _events = Channel.CreateUnbounded<ControlEvent>();
    private readonly Channel<ControlEnvelope> _outgoing = Channel.CreateUnbounded<ControlEnvelope>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _stop = new();
    private readonly byte[] _macNonce = ControlAuth.Nonce();
    /// <summary>Messages queued and not yet written and flushed to the stream; see <see cref="Unwritten"/>.</summary>
    private int _unwritten;

    /// <summary>Guards every field below; events and outgoing messages are queued under it, so their order is the order of decisions.</summary>
    private readonly Lock _gate = new();
    private bool _started;
    private bool _closed;
    private ITimer? _heartbeat;
    private Task _opening = Task.CompletedTask;
    private Task _running = Task.CompletedTask;
    /// <summary>When the phone last answered (welcome, pong, status, paired, error); silence is counted from it.</summary>
    private long _lastHeard;
    private bool _welcomed;
    /// <summary>The handshake is over (proved, or welcomed unpaired): pings may go out.</summary>
    private bool _settled;
    /// <summary>The phone proved the pairing (or paired here).</summary>
    private bool _authenticated;
    /// <summary>
    /// A <c>pair</c> is out and unanswered: the one time a <c>paired</c> counts. Set under the lock as the pair is
    /// queued (the reader decides under the same lock); cleared by its answer (paired or error) and on disconnect.
    /// </summary>
    private bool _pairing;
    /// <summary>A code entered before the phone's welcome; sent once it arrives.</summary>
    private string? _pendingCode;
    /// <summary>The cable peer check's verdict on this channel's stream, decided before <c>hello</c>.</summary>
    private PeerVerdict _peer = PeerVerdict.Unknown;

    public ChannelReader<ControlEvent> Events => _events.Reader;

    /// <summary>Who holds the far end of this channel, as the cable peer check found it (<see cref="PeerVerdict.Unknown"/> before the stream opens).</summary>
    public PeerVerdict Peer
    {
        get { lock (_gate) return _peer; }
    }

    /// <summary>
    /// Opens the stream and says hello; the rest runs in the background and is reported through <see cref="Events"/>.
    /// A failure to open is reported as <see cref="ControlEvent.Disconnected"/>, not thrown. Disposing the client
    /// cancels an open in progress. Call once.
    /// </summary>
    public Task StartAsync(CancellationToken ct)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_closed && !_started, this);
            if (_started) throw new InvalidOperationException("The control client is already started");
            _started = true;
            _opening = Task.Run(() => OpenAsync(ct)); // never faults
            return _opening;
        }
    }

    private async Task OpenAsync(CancellationToken ct)
    {
        var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _stop.Token);
        Task<Stream> pending;
        try
        {
            pending = open(linked.Token);
        }
        catch (Exception e)
        {
            linked.Dispose();
            lock (_gate) Finish(e);
            return;
        }
        _ = pending.ContinueWith(_ => linked.Dispose(), CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

        Stream stream;
        try
        {
            stream = await pending.WaitAsync(_stop.Token).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            // We gave up on the open (disposed, or it failed); a stream it yields, now or later, is never used.
            // Cancel the open ourselves (our own wait may have seen _stop before the link did), then let the source
            // go: an open that never completes must not keep it alive. After the open is over this does nothing.
            try { linked.Cancel(); }
            catch (ObjectDisposedException) { }
            linked.Dispose();
            _ = pending.ContinueWith(t =>
            {
                if (t.IsCompletedSuccessfully) t.Result.Dispose();
                _ = t.Exception; // observed
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            lock (_gate) Finish(e); // after a dispose this does nothing
            return;
        }

        // Judged on the stream itself, before anything goes out on it, so the verdict is about the connection used.
        var verdict = PeerVerdict.Unknown;
        if (inspect is not null)
        {
            try { verdict = inspect(stream); }
            catch (Exception) { verdict = PeerVerdict.Unknown; } // a check that fails grants nothing
        }

        var channel = new LineChannel(stream);
        lock (_gate)
        {
            if (!_closed)
            {
                _peer = verdict;
                StartChannel(channel);
                return;
            }
        }
        await channel.DisposeAsync().ConfigureAwait(false); // disposed just as the open finished
    }

    /// <summary>Says hello and starts the heartbeat and the background loops. Called under the lock.</summary>
    private void StartChannel(LineChannel channel)
    {
        _lastHeard = time.GetTimestamp();
        Send(new ControlEnvelope(ControlEnvelope.Hello)
        {
            ProtocolVersion = ProtocolConstants.Version,
            ClientID = identity.ClientId,
            Name = identity.Name,
            Nonce = Convert.ToBase64String(_macNonce),
            Via = "usb",
            HostKind = HostKind,
        });
        // Silence counts from here; pings wait for the handshake to settle.
        _heartbeat = time.CreateTimer(_ => Beat(), null, ProtocolConstants.PingInterval, ProtocolConstants.PingInterval);
        _running = RunAsync(channel);
    }

    /// <summary>
    /// Sends the six-digit code shown on the phone; held until the phone's welcome if it comes first. True when the
    /// code was taken (queued, or held, on an open channel, decided under the lock); false when the channel had
    /// already ended, even if its <see cref="ControlEvent.Disconnected"/> has not been read yet.
    /// </summary>
    public Task<bool> SubmitCodeAsync(string code)
    {
        lock (_gate)
        {
            if (_closed) return Task.FromResult(false);
            if (!_welcomed) _pendingCode = code;
            else SendPair(code);
        }
        return Task.FromResult(true);
    }

    /// <summary>
    /// Hands the phone a shell key and how to reach this PC (<c>shellGrant</c>). False, with nothing sent, unless the
    /// phone has proved the pairing on this channel and the cable peer check said <see cref="PeerVerdict.Genuine"/>,
    /// the key is 32 bytes and <paramref name="grantId"/> is 1 to 64 UTF-8 bytes. The phone answers
    /// <see cref="ControlEvent.ShellGranted"/> once it has stored the key, or not at all.
    /// </summary>
    public bool GrantShell(ReadOnlySpan<byte> shellKey, GrantContents contents, string grantId)
    {
        if (shellKey.Length != 32) return false;
        var idBytes = Encoding.UTF8.GetByteCount(grantId);
        if (idBytes is < 1 or > ControlEnvelope.MaxGrantIdLength) return false;
        var key = Convert.ToBase64String(shellKey);
        lock (_gate)
        {
            if (_closed || !_authenticated || _peer != PeerVerdict.Genuine) return false;
            Send(new ControlEnvelope(ControlEnvelope.ShellGrant)
            {
                ShellKey = key,
                CertSHA256 = contents.CertSHA256,
                ShellPort = contents.Port,
                Addresses = [.. contents.Addresses],
                MacName = contents.HostName,
                IrohID = contents.IrohId,
                IrohRelay = contents.IrohRelay,
                RelayToken = contents.RelayToken,
                GrantID = grantId,
                HostKind = HostKind,
            });
            return true;
        }
    }

    /// <summary>
    /// Closes the channel (reporting <see cref="ControlEvent.Disconnected"/> with no error, unless it already ended),
    /// cancels an open in progress, and waits for the background work to end.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        Task opening;
        lock (_gate)
        {
            Finish(null);
            opening = _opening;
        }
        await opening.ConfigureAwait(false);
        Task running;
        lock (_gate) running = _running; // final once the open is over
        await running.ConfigureAwait(false);
        _stop.Dispose(); // cancelled by Finish; nothing uses it once the open and the loops are over
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
            {
                await channel.WriteAsync(m, _stop.Token).ConfigureAwait(false);
                Interlocked.Decrement(ref _unwritten);
            }
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
            // Nothing goes out between hello and the phone's proof but our own proof.
            if (_settled) Send(new ControlEnvelope(ControlEnvelope.Ping));
        }
    }

    /// <summary>One message from the phone. Called under the lock.</summary>
    private void Handle(ControlEnvelope m)
    {
        if (_closed) return;
        // Only answers count as the phone being there: anything else could be sent forever without listening.
        if (m.T is ControlEnvelope.Welcome or ControlEnvelope.Pong or ControlEnvelope.Status or ControlEnvelope.Paired or ControlEnvelope.Error
            or ControlEnvelope.ShellGranted)
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
                if (m.Token is not { } token || !PairingToken.IsWellFormed(token))
                {
                    // No token, or not one a phone issues: nothing on this channel can be trusted, and the pairing
                    // would hang half-done. Send nothing, end it.
                    Finish(new ProtocolException("The phone sent a malformed pairing token."));
                    return;
                }
                _authenticated = true;
                Emit(new ControlEvent.PairedWith(token));
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
                if (!_pairing)
                {
                    // Not an answer to a code. After our auth, not_authenticated means the phone refused our proof
                    // (it closes next); anything else is no pairing failure, so it is not reported as one.
                    if (failure == PairingFailure.NotAuthenticated && _authenticated)
                        Finish(new ControlException(ControlErrorKind.NotAuthenticated, deviceKind));
                    return;
                }
                _pairing = false;
                Emit(new ControlEvent.PairingFailed(failure));
                break;
            case ControlEnvelope.Goodbye:
                if (_authenticated) Emit(new ControlEvent.Goodbye());
                break;
            case ControlEnvelope.ShellGranted:
                // Before the proofs it is anyone's word; an id the phones never send could forge a log line or a
                // settings key, so it is ignored.
                if (!_authenticated || !IsPhoneId(m.PhoneID)) return;
                var grantId = m.GrantID is { Length: > 0 } g && Encoding.UTF8.GetByteCount(g) <= ControlEnvelope.MaxGrantIdLength ? g : null;
                Emit(new ControlEvent.ShellGranted(m.PhoneID!, grantId));
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
        _settled = true;
        Emit(new ControlEvent.Welcomed(paired));
        if (!paired && _pendingCode is { } code)
        {
            _pendingCode = null;
            SendPair(code);
        }
    }

    /// <summary>What both phone apps send as their id: 1 to 64 letters, digits, <c>.</c>, <c>_</c> or <c>-</c>.</summary>
    internal static bool IsPhoneId(string? id) =>
        id is { Length: >= 1 and <= 64 } && id.All(c => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '.' or '_' or '-');

    private void SendPair(string code)
    {
        _pairing = true;
        Send(new ControlEnvelope(ControlEnvelope.Pair) { ClientID = identity.ClientId, Name = identity.Name, Code = code });
    }

    private void Send(ControlEnvelope m)
    {
        Interlocked.Increment(ref _unwritten);
        if (!_outgoing.Writer.TryWrite(m)) Interlocked.Decrement(ref _unwritten);
    }

    /// <summary>
    /// For tests: how many queued messages the writer has not yet written and flushed. Zero means nothing this client
    /// decided to send is still on its way to the stream, so a test can tell "not sent" from "not sent yet".
    /// </summary>
    internal int Unwritten => Volatile.Read(ref _unwritten);

    private void Emit(ControlEvent e)
    {
        if (!_closed) _events.Writer.TryWrite(e);
    }

    /// <summary>Ends the channel once: stops the heartbeat and the background loops, reports why as the last event, and completes <see cref="Events"/>. Called under the lock.</summary>
    private void Finish(Exception? error)
    {
        if (_closed) return;
        Emit(new ControlEvent.Disconnected(error));
        _closed = true;
        _pairing = false;
        _events.Writer.TryComplete();
        _outgoing.Writer.TryComplete();
        _heartbeat?.Dispose();
        _heartbeat = null;
        _stop.Cancel();
    }
}
