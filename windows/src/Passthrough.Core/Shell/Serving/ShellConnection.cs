using System.Threading.Channels;
using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Shell.Serving;

/// <summary>
/// One proven phone's connection (a port of ShellConnection in ShellListener.swift): it reads requests one at a time
/// and answers each in order, a slow one (starting a shell, listing history) holding back the ones after it; and it is
/// the <see cref="IShellAttachment"/> of the one session it is attached to. What it sends is queued: a phone that stops
/// reading is dropped at <see cref="SendBacklogLimit"/> rather than the host buffering for it without end; it can
/// attach again and is replayed the scrollback.
/// </summary>
public sealed class ShellConnection : IShellAttachment
{
    public const int SendBacklogLimit = 8 << 20;
    /// <summary>Most entries one <c>historyList</c> carries: the newest.</summary>
    internal const int HistoryLimit = 500;

    private readonly ShellGate _gate;
    private readonly ISessionHost _host;
    private readonly Stream _stream;

    /// <summary>Every 5 s of a view that is carrying something: what passed, how long the phone made us wait, and the link's numbers.</summary>
    private void LogProgress(Screen.Splice.Progress p)
    {
        if (p.FromA == 0 && p.ToA == 0) return;
        string link;
        try { link = _stream is IStreamPath s ? s.DescribeLink() : ""; }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException) { link = ""; }
        _gate.Log?.Invoke($"screen: {Label}'s view, last 5 s: {p.ToA} bytes out, {p.FromA} in; writes to it waited {p.BlockedToA.TotalMilliseconds:0} ms (longest {p.LongestWriteToA.TotalMilliseconds:0} ms); longest silence from it {p.LongestQuietFromA.TotalMilliseconds:0} ms; {(p.Held > TimeSpan.Zero ? $"held back {p.Held.TotalMilliseconds:0} ms for the relay's queue; " : "")}{PathNow()}{(link.Length > 0 ? "; " + link : "")}");
    }

    /// <summary>How this connection reaches the peer now: iroh's path, or the TLS listener on this network.</summary>
    private string PathNow()
    {
        try { return _stream is IStreamPath p ? p.DescribePath() : "this network (TLS)"; }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException) { return "path unknown"; }
    }
    private readonly ShellLineReader _reader;
    private readonly Channel<(byte[] Line, TaskCompletionSource? Written)> _outgoing =
        Channel.CreateUnbounded<(byte[], TaskCompletionSource?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _closing = new();
    private readonly Lock _lock = new();
    private long _backlog;
    private string? _attached;
    private ulong _generation;
    private ulong _nextGeneration;
    private Stream? _relay;
    private volatile bool _relaying;
    private Screen.RelayRecord? _view;
    private Screen.RelayRateLimit.Ticket? _ticket;

    /// <summary>This connection carries a view of the screen now, or is opening one (Remote Desktop's bytes, no more lines).</summary>
    internal bool IsRelaying => _relaying || _opening;

    private volatile bool _opening;
    private volatile bool _looking;
    private Stream? _clip;
    private volatile bool _clipping;

    /// <summary>This connection carries clipboard sync now (binary messages to the tray app, no more lines).</summary>
    internal bool IsClip => _clipping && !IsClosed;
    private int _closed;

    internal ShellConnection(ShellGate gate, ISessionHost host, Stream stream, ShellLineReader reader, string phoneId, string label)
    {
        _gate = gate;
        _host = host;
        _stream = stream;
        _reader = reader;
        PhoneId = phoneId;
        Label = label;
    }

    public string PhoneId { get; }
    public string Label { get; }
    public bool IsLooking => _looking;
    /// <summary>The shells of the account this phone belongs to.</summary>
    internal ISessionHost Host => _host;

    /// <summary>Sends <c>ready</c>, <c>macInfo</c>, <c>host</c>, the state and the session list, then serves requests until the phone goes.</summary>
    internal async Task RunAsync()
    {
        var writer = WriteAllAsync();
        Send(new ShellEnvelope(ShellEnvelope.Ready));
        if (_gate.Hooks.MacInfo() is { } info) Send(info);
        SendHost();
        // A computer without the shell scope gets no state and no sessions (stage 7 a.3).
        if (ShellScope) SendState();
        if (ShellScope) SendSessions(_host.Sessions);
        try
        {
            while (await _reader.ReadLineAsync(_closing.Token).ConfigureAwait(false) is { } line)
            {
                await HandleAsync(line).ConfigureAwait(false);
                if (_relay is not null || _clip is not null) break;
            }
        }
        catch (LineTooLongException) { _gate.Log?.Invoke("shell: a phone sent an overlong line; disconnected"); }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
        if (_relay is { } relay && !IsClosed)
        {
            // rdpReady is written; no other line may follow it. From here the connection is Remote Desktop's bytes.
            _relaying = true;
            _outgoing.Writer.TryComplete();
            await writer.ConfigureAwait(false);
            // NLA on every relayed connection, whatever the PC allows: the first PDU each way is read before splicing.
            bool nla;
            try
            {
                using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                nla = await Screen.RdpNegotiation.EnforceAsync(_stream, relay, limit.Token,
                    why => _gate.Log?.Invoke($"screen: no Network Level Authentication: {why}")).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { nla = false; }
            if (nla)
            {
                var (fromPhone, toPhone) = await Screen.Splice.RunAsync(_stream, relay, report: LogProgress,
                    roundTripToA: _stream is IStreamPath paced ? () => paced.RelayRoundTrip : null).ConfigureAwait(false);
                EndView(fromPhone, toPhone, IsClosed ? "Stop" : "the phone or Remote Desktop");
            }
            else
            {
                _gate.Log?.Invoke("screen: a view was closed: it didn't use Network Level Authentication");
                EndView(0, 0, "no Network Level Authentication");
            }
        }
        if (_clip is { } clip && !IsClosed)
        {
            // clipSyncReady is written; from here the connection is clipboard sync's bytes, passed to the tray app and back as they are.
            _outgoing.Writer.TryComplete();
            await writer.ConfigureAwait(false);
            _gate.Log?.Invoke($"clipsync: {Label} syncs the clipboard ({PathNow()})");
            var (fromDevice, toDevice) = await PassAsync(_stream, clip).ConfigureAwait(false);
            _gate.Log?.Invoke($"clipsync: {Label}'s sync ended ({fromDevice} bytes in, {toDevice} out)");
        }
        // Closed between rdpReady and the splice: the view's slot is freed all the same.
        EndView(0, 0, "Stop");
        Close();
        await writer.ConfigureAwait(false);
    }

    /// <summary>
    /// Passes bytes both ways until either side ends, each write awaited before the next read: a side that stops
    /// reading holds the other back, and nothing piles up here. Then both are closed.
    /// </summary>
    private static async Task<(long FromA, long FromB)> PassAsync(Stream a, Stream b)
    {
        using var stop = new CancellationTokenSource();
        async Task<long> OneWay(Stream from, Stream to)
        {
            var buffer = new byte[64 << 10];
            long total = 0;
            try
            {
                int n;
                while ((n = await from.ReadAsync(buffer, stop.Token).ConfigureAwait(false)) > 0)
                {
                    await to.WriteAsync(buffer.AsMemory(0, n), stop.Token).ConfigureAwait(false);
                    await to.FlushAsync(stop.Token).ConfigureAwait(false);
                    total += n;
                }
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException or InvalidOperationException) { }
            return total;
        }
        var aToB = OneWay(a, b);
        var bToA = OneWay(b, a);
        await Task.WhenAny(aToB, bToA).ConfigureAwait(false);
        stop.Cancel();
        a.Dispose();
        b.Dispose();
        return (await aToB.ConfigureAwait(false), await bToA.ConfigureAwait(false));
    }

    /// <summary>
    /// <c>clipSync</c> (protocol/README.md, "Clipboard sync"): between computers only, with the screen scope, while this
    /// device views the screen. The account's tray app owns the clipboard, so the connection is handed to it: the
    /// answer is <c>clipSyncReady</c>, then binary messages both ways. A refusal leaves this a shell connection.
    /// </summary>
    private async Task ClipSyncAsync()
    {
        // A phone keeps its Copy and Paste. A screen pass can't view a PC's screen, so it is never viewing.
        if (!IsComputer) { Fail(PhoneId.StartsWith("viewer.", StringComparison.Ordinal) ? ShellError.NoScreenView : ShellError.NotAllowed); return; }
        if (!_gate.Access.ScreenAllowed(PhoneId)) { Fail(ShellError.ScreenNotAllowed); return; }
        if (!_gate.IsViewing(PhoneId)) { Fail(ShellError.NoScreenView); return; }
        if (_gate.Hooks.ClipSync is not { } open) { Fail(ShellError.ClipSyncUnavailable); return; }
        Stream? stream = null;
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(_closing.Token);
            limit.CancelAfter(TimeSpan.FromSeconds(8));
            (stream, var error) = await open(PhoneId, Label, limit.Token).ConfigureAwait(false);
            if (stream is null)
            {
                _gate.Log?.Invoke($"clipsync: refused {Label}: {(error ?? ShellError.ClipSyncUnavailable).ToWire()}");
                Fail(error ?? ShellError.ClipSyncUnavailable);
                return;
            }
            // It must have waited for the answer: anything sent since would be read as clipboard sync unasked.
            if (_reader.HasBuffered) { Close(); return; }
            // The view may have ended, or Screen been turned off, meanwhile: asked again, last thing.
            if (!_gate.Access.ScreenAllowed(PhoneId)) { Fail(ShellError.ScreenNotAllowed); return; }
            if (!_gate.IsViewing(PhoneId)) { Fail(ShellError.NoScreenView); return; }
            lock (_lock) _attached = null;
            _host.Detach(this);
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Enqueue(new ShellEnvelope(ShellEnvelope.ClipSyncReady).EncodeLine(), ready, last: true);
            await ready.Task.ConfigureAwait(false);
            if (IsClosed) return;
            _clipping = true;
            _clip = stream;
            stream = null;
            _gate.ClipSyncStarted(this);
            // The last view may have ended between the check and now: nothing else would close this.
            if (!_gate.IsViewing(PhoneId)) _gate.ViewEnded(PhoneId);
        }
        catch (OperationCanceledException) { Fail(ShellError.ClipSyncUnavailable); }
        finally { stream?.Dispose(); }
    }

    private void EndView(long fromPhone, long toPhone, string endedBy)
    {
        if (_view is not { } view) return;
        _view = null;
        _gate.Views.Release(PhoneId);
        _gate.ViewEnded(PhoneId);
        if (_ticket is { } ticket) _gate.RelayRate.Closed(ticket);
        _gate.Log?.Invoke($"screen: {Label}'s view ended ({endedBy}; {fromPhone} bytes in, {toPhone} out; {PathNow()} at the end)");
        _gate.Hooks.ViewEnded?.Invoke(view with { End = _gate.Time.GetUtcNow(), BytesIn = fromPhone, BytesOut = toPhone, EndedBy = endedBy });
    }

    /// <summary>
    /// <c>rdp</c> (stage 5 plan, section 4; RECONCILIATION's refusal order): screen-only passes, then the Screen switch,
    /// then views at once, then whether Remote Desktop can be relayed to, then the open-rate caps. Then the dial, whose
    /// far end must be Windows' Remote Desktop service, the certificate to expect, <c>rdpReady</c>, and the splice.
    /// A refusal leaves this a shell connection.
    /// </summary>
    private async Task RelayAsync()
    {
        // Windows' own log shows only 127.0.0.1: every ask, refusal and view is in the service's, with the device.
        _gate.Log?.Invoke($"screen: {Label} asked for the screen");
        if (PhoneId.StartsWith("viewer.", StringComparison.Ordinal)) { Refused("a screen-only pass"); Fail(ShellError.ScreenOnly); return; }
        if (!_gate.Access.ScreenAllowed(PhoneId)) { Refused("Screen is off for it"); Fail(ShellError.ScreenNotAllowed); return; }
        if (_gate.Hooks.RemoteDesktop is not { } desktop)
        {
            var why = _gate.Hooks.RdpUnavailable(PhoneId);
            Refused($"Remote Desktop can't be relayed to ({why})");
            Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = why });
            return;
        }
        if (!_gate.Views.TryTake(PhoneId)) { Refused("too many views"); Fail(ShellError.TooManyScreens); return; }
        _opening = true;
        var released = false;
        void Release()
        {
            if (released) return;
            released = true;
            _gate.Views.Release(PhoneId);
        }
        Stream? dial = null;
        try
        {
            // A view leaves any session it was attached to.
            lock (_lock) _attached = null;
            _host.Detach(this);
            var account = _gate.Hooks.AccountOf(PhoneId);
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var verdict = await desktop.CheckAsync(account, limit.Token).ConfigureAwait(false);
            if (verdict.Port is not { } port)
            {
                Refused($"Remote Desktop can't be relayed to ({verdict.Unavailable ?? "service"})");
                Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = verdict.Unavailable ?? "service" });
                return;
            }
            var stopped = _gate.StoppedFor(PhoneId);
            var ticket = stopped > 0 ? null : _gate.RelayRate.TryReserve(account ?? "", PhoneId, out stopped);
            if (ticket is null)
            {
                Refused($"too many views lately; again in {stopped} s");
                Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.TryLater.ToWire(), RetryAfter = stopped });
                return;
            }
            _ticket = ticket;
            using var dialLimit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            dial = await desktop.DialAsync(port, dialLimit.Token).ConfigureAwait(false);
            if (dial is null)
            {
                _gate.Log?.Invoke("screen: what answers on Remote Desktop's port is not Remote Desktop, or nothing does");
                Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = "service" });
                return;
            }
            using var certLimit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            if (await desktop.CertificateSha256Async(certLimit.Token).ConfigureAwait(false) is not { Length: 64 } pin)
            {
                Refused("Remote Desktop's certificate couldn't be read");
                Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = "service" });
                return;
            }
            // The phone must have waited for the answer: anything it sent since would go to Remote Desktop unasked.
            if (_reader.HasBuffered) { Close(); return; }
            // Screen may have been turned off, or the view stopped, while this was dialling: asked again, last thing.
            if (!_gate.Access.ScreenAllowed(PhoneId)) { Fail(ShellError.ScreenNotAllowed); return; }
            if (_gate.StoppedFor(PhoneId) is > 0 and var stoppedNow)
            {
                Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.TryLater.ToWire(), RetryAfter = stoppedNow });
                return;
            }
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Enqueue(new ShellEnvelope(ShellEnvelope.RdpReady) { CertSHA256 = pin }.EncodeLine(), ready, last: true);
            await ready.Task.ConfigureAwait(false);
            if (IsClosed) return;
            _view = new Screen.RelayRecord(PhoneId, Label, account, "", _gate.Time.GetUtcNow());
            _gate.Log?.Invoke($"screen: {Label}'s view started ({PathNow()})");
            _gate.Hooks.ViewStarted?.Invoke(_view);
            released = true; // the view is the relay's now; it is freed when the splice ends
            // Relaying from here, before _opening clears: Screen turned off or Stop in between closes this connection.
            _relaying = true;
            _relay = dial;
            dial = null;
        }
        catch (OperationCanceledException)
        {
            Refused("Remote Desktop didn't answer in time");
            Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = "service" });
        }
        finally
        {
            _opening = false;
            dial?.Dispose();
            // Refused after the ticket was taken: it reached nothing, so it doesn't count.
            if (_relay is null && _ticket is { } unused) { _gate.RelayRate.Cancel(unused); _ticket = null; }
            Release();
        }
    }

    private void Refused(string why) => _gate.Log?.Invoke($"screen: refused {Label}: {why}");

    /// <summary>
    /// A phone gives another of its computers access (stage 7 a.2): the host's rules decide, then the new id and key go
    /// back (<c>computerGranted</c>), with the scopes that wait for the owner here (<c>pending</c>).
    /// </summary>
    private void GrantComputer(ShellEnvelope m)
    {
        byte[]? idKey = null;
        try { idKey = m.IdKey is { } k ? Convert.FromBase64String(k) : null; } catch (FormatException) { }
        if (m.Name is not { } name || m.Viewer is not { } viewer || idKey is null || m.Scopes is not { Count: > 0 } scopes) { Fail(ShellError.BadRequest); return; }
        var (computer, error) = _gate.Access.GrantComputer(PhoneId, name, viewer, m.Kind, idKey, scopes.ToHashSet(StringComparer.Ordinal), _gate.Hooks.ScreenNeedsOwner);
        if (computer is null) { Fail(error ?? ShellError.BadRequest); return; }
        var granted = new List<string>();
        if (computer.Shell == true) granted.Add(Access.Computers.ScopeShell);
        if (computer.Screen == true && computer.ScreenPending != true) granted.Add(Access.Computers.ScopeScreen);
        Send(new ShellEnvelope(ShellEnvelope.ComputerGranted)
        {
            PhoneID = computer.Id,
            Key = Convert.ToBase64String(computer.Key),
            Scopes = granted,
            Pending = computer.ScreenPending == true ? [Access.Computers.ScopeScreen] : null,
        });
        _gate.Hooks.ComputerGranted?.Invoke(Label, computer);
        Event($"gave {computer.Name} access");
    }

    /// <summary>Another of this phone's connections had its view stopped from the PC (<c>screenEnded</c>).</summary>
    internal void SendScreenEnded(string reason) => Send(new ShellEnvelope(ShellEnvelope.ScreenEnded) { Reason = reason });

    /// <summary>Ends the connection and stops the manager sending to it. Idempotent.</summary>
    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _host.Gone(this);
        lock (_lock) _attached = null;
        _outgoing.Writer.TryComplete();
        _closing.Cancel();
        _stream.Dispose();
        _relay?.Dispose();
        _clip?.Dispose();
        _gate.Log?.Invoke("shell: a phone disconnected");
    }

    private bool IsClosed => Volatile.Read(ref _closed) == 1;

    // MARK: Requests

    /// <summary>A computer's connection (stage 7 a.3): what it may do is its scopes, asked from memory each time.</summary>
    private bool IsComputer => Access.Computers.IsComputerId(PhoneId);

    /// <summary>It may use the shell: a phone always (its Shell switch is checked elsewhere), a computer with its shell scope.</summary>
    private bool ShellScope => !IsComputer || _gate.Access.Computer(PhoneId)?.Shell == true;

    /// <summary>What a computer may ask (stage 7 a.3's table); null when it may, else why not.</summary>
    private ShellError? ComputerRefusal(string? t)
    {
        if (!IsComputer) return null;
        if (_gate.Access.Computer(PhoneId) is not { } computer) return ShellError.NotAuthorized; // revoked since
        return t switch
        {
            ShellEnvelope.Ping or ShellEnvelope.Pong => null,
            ShellEnvelope.List or ShellEnvelope.Open or ShellEnvelope.Attach or ShellEnvelope.Input or ShellEnvelope.Resize
                or ShellEnvelope.Close or ShellEnvelope.Viewing => computer.Shell == true ? null : ShellError.NotAllowed,
            // rdp and clipSync check the screen scope themselves; screen and screenVideo are refused as for anyone on a PC.
            ShellEnvelope.Rdp or ShellEnvelope.Screen or ShellEnvelope.ScreenVideo or ShellEnvelope.ClipSync => null,
            _ => ShellError.NotAllowed,
        };
    }

    private async Task HandleAsync(byte[] line)
    {
        ShellEnvelope message;
        try { message = ShellEnvelope.Decode(line); }
        catch (Protocol.ProtocolException) { Fail(ShellError.BadRequest); return; }
        if (ComputerRefusal(message.T) is { } computerRefusal)
        {
            Fail(computerRefusal, message.Session, message.Ref);
            if (computerRefusal == ShellError.NotAuthorized) Close();
            return;
        }
        switch (message.T)
        {
            case ShellEnvelope.ComputerGrant:
                GrantComputer(message);
                break;
            case ShellEnvelope.ComputerPass:
                if (message.Pass is null || _gate.Hooks.SaveComputerPass is not { } save) { Fail(ShellError.BadRequest); break; }
                if (await save(PhoneId, Label, message).ConfigureAwait(false) is { } notSaved) Fail(notSaved);
                else Send(new ShellEnvelope(ShellEnvelope.ComputerPassSaved));
                break;
            case ShellEnvelope.ComputerRevoke:
                if (message.PhoneID is not { } revoking || !_gate.Access.RevokeComputer(revoking, PhoneId)) { Fail(ShellError.BadRequest); break; }
                _gate.Disconnect(revoking);
                // Its owner is this phone's account: the gate can no longer look that up, so its sessions are closed here.
                _host.CloseSessions(revoking);
                Send(new ShellEnvelope(ShellEnvelope.ComputerRevoked));
                break;
            case ShellEnvelope.ListComputers:
                _listsComputers = true;
                SendComputers();
                break;
            case ShellEnvelope.List:
                SendSessions(_host.Sessions);
                break;
            case ShellEnvelope.Open:
                if (message.Cols is not { } cols || message.Rows is not { } rows) { Fail(ShellError.BadRequest, @ref: message.Ref); break; }
                await OpenAsync(cols, rows, message.Shell, message.Ref).ConfigureAwait(false);
                break;
            case ShellEnvelope.Attach:
                if (message.Session is not { } id || message.Cols is not { } c || message.Rows is not { } r) { Fail(ShellError.BadRequest); break; }
                if (!_host.IsAvailable) { Fail(ShellError.SignedOut, id); break; }
                if (await AttachAsync(id, c, r).ConfigureAwait(false)) Event("attached to a session");
                break;
            case ShellEnvelope.Input:
                byte[]? data = null;
                try { data = message.Data is { } d ? Convert.FromBase64String(d) : null; } catch (FormatException) { }
                string? current;
                lock (_lock) current = _attached;
                if (message.Session is null || message.Session != current || data is null) { Fail(ShellError.BadRequest, message.Session); break; }
                _host.Input(current, data, this);
                break;
            case ShellEnvelope.Resize:
                // For whatever is attached when the line is read: lines wait behind an open, so a resize sent before
                // `opened` reaches the new session. The session named is ignored.
                if (message.Cols is not { } rc || message.Rows is not { } rr) { Fail(ShellError.BadRequest, message.Session); break; }
                string? target;
                lock (_lock) target = _attached;
                if (target is not null) _host.Resize(target, rc, rr, this);
                break;
            case ShellEnvelope.Close:
                if (message.Session is not { } closing) { Fail(ShellError.BadRequest); break; }
                if (!_host.Sessions.Any(s => s.Id == closing && s.Running)) { Fail(ShellError.NoSuchSession, closing); break; }
                _host.Close(closing);
                Event("closed a session");
                break;
            case ShellEnvelope.History:
                if (!_host.IsAvailable) { Fail(ShellError.SignedOut); break; }
                try { Send(HistoryReply(await _host.HistoryAsync().ConfigureAwait(false))); }
                catch (ShellException e) { Fail(e.Error); }
                break;
            case ShellEnvelope.Transcript:
                if (message.Session is not { } wanted) { Fail(ShellError.BadRequest); break; }
                // Session ids are UUIDs the host made: nothing else a phone names may reach the file system (B-9).
                if (!Guid.TryParseExact(wanted, "D", out _)) { Fail(ShellError.NoSuchSession, wanted); break; }
                if (!_host.IsAvailable) { Fail(ShellError.SignedOut, wanted); break; }
                await SendTranscriptAsync(wanted).ConfigureAwait(false);
                break;
            case ShellEnvelope.Viewing:
                if (message.On is not { } on) { Fail(ShellError.BadRequest); break; }
                _looking = on;
                _host.SetViewing(this, on);
                break;
            case ShellEnvelope.Lock:
                if (_gate.Hooks.Lock is not { } lockScreen) { Fail(ShellError.BadRequest); break; }
                if (!_host.IsAvailable) { Fail(ShellError.SignedOut); break; }
                if (lockScreen(PhoneId) is { } refused) Fail(refused);
                else _ = AnswerStateLaterAsync();
                break;
            // What a PC answers to what only a Mac does (protocol/README.md, "A Windows PC as host").
            case ShellEnvelope.SetAwake or ShellEnvelope.SetVpn:
                Fail(ShellError.NotAllowed);
                break;
            case ShellEnvelope.Events:
                if (message.Since is not { } since || !double.IsFinite(since)) { Fail(ShellError.BadRequest); break; }
                Send(new ShellEnvelope(ShellEnvelope.EventList) { Since = since, EventEntries = [], Battery = [] });
                break;
            case ShellEnvelope.PushRegister:
                Send(new ShellEnvelope(ShellEnvelope.PushState) { On = false });
                break;
            // Until the PC has its own stream, both are refused alike: the Mac's Screen Sharing login must never come up
            // for a PC (RECONCILIATION, the PC's answer table). The screen comes through rdp.
            case ShellEnvelope.Screen or ShellEnvelope.ScreenVideo:
                Fail(ShellError.ScreenNotAllowed);
                break;
            case ShellEnvelope.Rdp:
                await RelayAsync().ConfigureAwait(false);
                break;
            case ShellEnvelope.ClipSync:
                await ClipSyncAsync().ConfigureAwait(false);
                break;
            case ShellEnvelope.ScreenGrant or ShellEnvelope.ScreenPass or ShellEnvelope.ScreenRevoke:
                Fail(ShellError.BadRequest);
                break;
            case ShellEnvelope.Ping:
                Send(new ShellEnvelope(ShellEnvelope.Pong));
                break;
            case ShellEnvelope.Pong:
                break;
            default:
                Fail(ShellError.BadRequest);
                break;
        }
    }

    /// <summary>
    /// Starts a shell off this connection's reading (spawning one must not hold up anything else), then answers and
    /// attaches; this connection's later requests wait until then. The answer carries the phone's <c>ref</c>.
    /// </summary>
    private async Task OpenAsync(int cols, int rows, string? shell, int? @ref)
    {
        if (shell is not null && !HostShell.IsValidId(shell)) { Fail(ShellError.BadRequest, @ref: @ref); return; }
        if (!_host.IsAvailable) { Fail(ShellError.SignedOut, @ref: @ref); return; }
        string id;
        try { id = await _host.OpenAsync(Label, cols, rows, PhoneId, shell).ConfigureAwait(false); }
        catch (ShellException e) { Fail(e.Error, @ref: @ref, message: e.Error == ShellError.BadRequest ? null : e.Message); return; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or ArgumentException)
        {
            _gate.Log?.Invoke($"shell: a shell could not start ({e.GetType().Name})");
            Fail(ShellError.BadRequest, @ref: @ref);
            return;
        }
        if (IsClosed) return; // gone meanwhile: the session runs on, as one a phone left does
        Event("opened a session");
        Send(new ShellEnvelope(ShellEnvelope.Opened) { Session = id, Cols = cols, Rows = rows, Ref = @ref });
        await AttachAsync(id, cols, rows).ConfigureAwait(false);
    }

    /// <summary>Attaches to <paramref name="id"/>, leaving any other session first. False if there is no such session.</summary>
    private async Task<bool> AttachAsync(string id, int cols, int rows)
    {
        string? before;
        ulong generation;
        lock (_lock) { before = _attached; _attached = id; }
        if (before != id) _host.Detach(this);
        // Chosen here, before the attach is asked for: a takeover notice for it may arrive before the answer does.
        lock (_lock) { _attached = id; generation = _generation = ++_nextGeneration; }
        try
        {
            await _host.AttachAsync(id, this, cols, rows, generation).ConfigureAwait(false);
            return true;
        }
        catch (ShellException e)
        {
            lock (_lock) _attached = null;
            Fail(e.Error, id);
            return false;
        }
    }

    /// <summary>A <c>historyList</c> for <paramref name="entries"/> (newest first): the newest that fit on one line.</summary>
    internal static ShellEnvelope HistoryReply(IReadOnlyList<ShellHistoryEntry> entries)
    {
        ShellEnvelope Reply(int count) => new(ShellEnvelope.HistoryList) { HistoryEntries = [.. entries.Take(count)] };
        bool Fits(int count) => Reply(count).EncodeLine().Length <= RemoteShell.LineLimit;
        var count = Math.Min(entries.Count, HistoryLimit);
        if (!Fits(count))
        {
            int low = 0, high = count;
            while (high - low > 1)
            {
                var mid = (low + high) / 2;
                if (Fits(mid)) low = mid; else high = mid;
            }
            count = low;
        }
        return Reply(count);
    }

    /// <summary>The transcript's end, a line at a time, each once the one before it was written.</summary>
    private async Task SendTranscriptAsync(string id)
    {
        IReadOnlyList<ShellEnvelope> lines;
        try { lines = await _host.TranscriptAsync(id).ConfigureAwait(false); }
        catch (ShellException e) { Fail(e.Error, id); return; }
        foreach (var line in lines)
        {
            if (IsClosed) return;
            await SendAndWaitAsync(line).ConfigureAwait(false);
        }
    }

    private async Task AnswerStateLaterAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(1), _gate.Time).ConfigureAwait(false);
        SendState();
    }

    private void Event(string what) => _gate.Hooks.Event?.Invoke($"{Label} {what}");

    // MARK: Unasked

    internal void SendSessions(IReadOnlyList<ShellSessionInfo> list)
    {
        if (ShellScope) Send(new ShellEnvelope(ShellEnvelope.Sessions) { SessionList = [.. list] });
    }

    internal void SendState()
    {
        if (ShellScope && _gate.Hooks.State(PhoneId) is { } state) Send(new ShellEnvelope(ShellEnvelope.MacState) { State = state });
    }

    /// <summary>Asked for the computers this phone gave access to: from then on it hears each change.</summary>
    private volatile bool _listsComputers;

    /// <summary><c>computerList</c>, on a connection that asked for it once (older phones never see it).</summary>
    internal void SendComputers()
    {
        if (!_listsComputers) return;
        var connected = _gate.ConnectedPhones.ToHashSet(StringComparer.Ordinal);
        Send(new ShellEnvelope(ShellEnvelope.ComputerList)
        {
            Computers = [.. _gate.Access.ComputersGrantedBy(PhoneId).Take(Access.Computers.MaxTotal).Select(c => new ComputerListEntry
            {
                PhoneID = c.Id,
                Viewer = c.ViewerOf.Length > 0 ? c.ViewerOf : null,
                Name = Access.ShellAccessStore.CleanLabel(c.Name),
                Kind = c.Kind,
                Scopes = [.. new[] { c.Shell == true ? Access.Computers.ScopeShell : null, c.Screen == true ? Access.Computers.ScopeScreen : null }.OfType<string>()],
                Pending = c.ScreenPending == true ? [Access.Computers.ScopeScreen] : null,
                Connected = connected.Contains(c.Id),
                GrantedAt = c.GrantedAt.ToUnixTimeSeconds(),
            })],
        });
    }

    internal void SendHost()
    {
        if (_gate.Hooks.Host(PhoneId) is not { } host) return;
        // A computer without the shell scope isn't told the shells.
        Send(new ShellEnvelope(ShellEnvelope.Host) { HostInfo = ShellScope ? host : host with { Shells = [] } });
    }

    // MARK: Sending

    private void Fail(ShellError reason, string? session = null, int? @ref = null, string? message = null) =>
        Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = reason.ToWire(), Session = session, Ref = @ref, Message = message });

    /// <summary>Queues a line; a phone that has let <see cref="SendBacklogLimit"/> pile up is dropped.</summary>
    private void Send(ShellEnvelope message) => Enqueue(message.EncodeLine(), null);

    /// <summary>Queues a line and completes once it is written (or the connection is gone).</summary>
    internal Task SendAndWaitAsync(ShellEnvelope message)
    {
        var written = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(message.EncodeLine(), written);
        return written.Task;
    }

    /// <summary>Set as <c>rdpReady</c> is queued: it is the last line, and anything after it would corrupt Remote Desktop's bytes.</summary>
    private bool _sealed;

    private void Enqueue(byte[] line, TaskCompletionSource? written, bool last = false)
    {
        lock (_lock)
        {
            if (IsClosed || _relaying || _clipping || _sealed) { written?.TrySetResult(); return; }
            if (last) _sealed = true;
        }
        if (Interlocked.Add(ref _backlog, line.Length) > SendBacklogLimit)
        {
            _gate.Log?.Invoke("shell: a phone is not reading its output; disconnected");
            written?.TrySetResult();
            Close();
            return;
        }
        if (!_outgoing.Writer.TryWrite((line, written))) written?.TrySetResult();
    }

    private async Task WriteAllAsync()
    {
        try
        {
            await foreach (var (line, written) in _outgoing.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                await _stream.WriteAsync(line).ConfigureAwait(false);
                Interlocked.Add(ref _backlog, -line.Length);
                written?.TrySetResult();
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { Close(); }
        while (_outgoing.Reader.TryRead(out var left)) left.Written?.TrySetResult();
    }

    // MARK: IShellAttachment (on the manager's callouts: hand off, never block)

    public void ShellOutput(byte[] data, string session)
    {
        if (!IsAttached(session)) return;
        for (var offset = 0; offset < data.Length; offset += RemoteShell.OutputChunk)
        {
            var piece = data.AsSpan(offset, Math.Min(RemoteShell.OutputChunk, data.Length - offset));
            Send(new ShellEnvelope(ShellEnvelope.Output) { Session = session, Data = Convert.ToBase64String(piece) });
        }
    }

    public void ShellEnded(string session, int exitStatus)
    {
        lock (_lock)
        {
            if (_attached != session) return;
            _attached = null;
        }
        Send(new ShellEnvelope(ShellEnvelope.Ended) { Session = session, ExitStatus = exitStatus });
    }

    public void ShellReplaying(string session)
    {
        if (IsAttached(session)) Send(new ShellEnvelope(ShellEnvelope.Replaying) { Session = session });
    }

    public void ShellReplayed(string session)
    {
        if (IsAttached(session)) Send(new ShellEnvelope(ShellEnvelope.Attached) { Session = session });
    }

    public void ShellDetached(string session, ulong generation)
    {
        lock (_lock)
        {
            // A takeover of an earlier attach, queued before this one: not ours to act on.
            if (_attached != session || generation != _generation) return;
            _attached = null;
        }
        Send(new ShellEnvelope(ShellEnvelope.Detached) { Session = session });
    }

    public void ShellDropped()
    {
        _gate.Log?.Invoke("shell: a phone's output backed up on the way from the tray app; disconnected");
        Close();
    }

    private bool IsAttached(string session)
    {
        lock (_lock) return _attached == session;
    }
}
