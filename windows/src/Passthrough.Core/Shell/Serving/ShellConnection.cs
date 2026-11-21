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
    private readonly Stream _stream;
    private readonly ShellLineReader _reader;
    private readonly Channel<(byte[] Line, TaskCompletionSource? Written)> _outgoing =
        Channel.CreateUnbounded<(byte[], TaskCompletionSource?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _closing = new();
    private readonly Lock _lock = new();
    private long _backlog;
    private string? _attached;
    private ulong _generation;
    private volatile bool _looking;
    private int _closed;

    internal ShellConnection(ShellGate gate, Stream stream, ShellLineReader reader, string phoneId, string label)
    {
        _gate = gate;
        _stream = stream;
        _reader = reader;
        PhoneId = phoneId;
        Label = label;
    }

    public string PhoneId { get; }
    public string Label { get; }
    public bool IsLooking => _looking;
    private ShellSessionManager Manager => _gate.Manager;

    /// <summary>Sends <c>ready</c>, <c>macInfo</c>, <c>host</c>, the state and the session list, then serves requests until the phone goes.</summary>
    internal async Task RunAsync()
    {
        var writer = WriteAllAsync();
        Send(new ShellEnvelope(ShellEnvelope.Ready));
        if (_gate.Hooks.MacInfo() is { } info) Send(info);
        SendHost();
        SendState();
        SendSessions(Manager.Sessions);
        try
        {
            while (await _reader.ReadLineAsync(_closing.Token).ConfigureAwait(false) is { } line)
                await HandleAsync(line).ConfigureAwait(false);
        }
        catch (LineTooLongException) { _gate.Log?.Invoke("shell: a phone sent an overlong line; disconnected"); }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
        Close();
        await writer.ConfigureAwait(false);
    }

    /// <summary>Ends the connection and stops the manager sending to it. Idempotent.</summary>
    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        Manager.Detach(this);
        lock (_lock) _attached = null;
        _outgoing.Writer.TryComplete();
        _closing.Cancel();
        _stream.Dispose();
        _gate.Log?.Invoke("shell: a phone disconnected");
    }

    private bool IsClosed => Volatile.Read(ref _closed) == 1;

    // MARK: Requests

    private async Task HandleAsync(byte[] line)
    {
        ShellEnvelope message;
        try { message = ShellEnvelope.Decode(line); }
        catch (Protocol.ProtocolException) { Fail(ShellError.BadRequest); return; }
        switch (message.T)
        {
            case ShellEnvelope.List:
                SendSessions(Manager.Sessions);
                break;
            case ShellEnvelope.Open:
                if (message.Cols is not { } cols || message.Rows is not { } rows) { Fail(ShellError.BadRequest, @ref: message.Ref); break; }
                await OpenAsync(cols, rows, message.Shell, message.Ref).ConfigureAwait(false);
                break;
            case ShellEnvelope.Attach:
                if (message.Session is not { } id || message.Cols is not { } c || message.Rows is not { } r) { Fail(ShellError.BadRequest); break; }
                if (Attach(id, c, r)) Event("attached to a session");
                break;
            case ShellEnvelope.Input:
                byte[]? data = null;
                try { data = message.Data is { } d ? Convert.FromBase64String(d) : null; } catch (FormatException) { }
                string? current;
                lock (_lock) current = _attached;
                if (message.Session is null || message.Session != current || data is null) { Fail(ShellError.BadRequest, message.Session); break; }
                Manager.Input(current, data, this);
                break;
            case ShellEnvelope.Resize:
                // For whatever is attached when the line is read: lines wait behind an open, so a resize sent before
                // `opened` reaches the new session. The session named is ignored.
                if (message.Cols is not { } rc || message.Rows is not { } rr) { Fail(ShellError.BadRequest, message.Session); break; }
                string? target;
                lock (_lock) target = _attached;
                if (target is not null) Manager.Resize(target, rc, rr, this);
                break;
            case ShellEnvelope.Close:
                if (message.Session is not { } closing) { Fail(ShellError.BadRequest); break; }
                if (!Manager.Sessions.Any(s => s.Id == closing && s.Running)) { Fail(ShellError.NoSuchSession, closing); break; }
                Manager.Close(closing);
                Event("closed a session");
                break;
            case ShellEnvelope.History:
                var entries = await Task.Run(() => _gate.Transcripts.Entries()).ConfigureAwait(false);
                Send(HistoryReply(entries));
                break;
            case ShellEnvelope.Transcript:
                if (message.Session is not { } wanted) { Fail(ShellError.BadRequest); break; }
                // Session ids are UUIDs the host made: nothing else a phone names may reach the file system (B-9).
                if (!Guid.TryParseExact(wanted, "D", out _)) { Fail(ShellError.NoSuchSession, wanted); break; }
                await SendTranscriptAsync(wanted).ConfigureAwait(false);
                break;
            case ShellEnvelope.Viewing:
                if (message.On is not { } on) { Fail(ShellError.BadRequest); break; }
                _looking = on;
                if (on) Manager.LookedAt(this);
                break;
            case ShellEnvelope.Lock:
                if (_gate.Hooks.Lock is not { } lockScreen) { Fail(ShellError.BadRequest); break; }
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
                if (!_gate.Access.ScreenAllowed(PhoneId)) Fail(ShellError.ScreenNotAllowed);
                else Send(new ShellEnvelope(ShellEnvelope.Error) { Reason = ShellError.RdpUnavailable.ToWire(), Detail = _gate.Hooks.RdpUnavailable(PhoneId) });
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
        string id;
        try { id = await Task.Run(() => Manager.Open(Label, cols, rows, PhoneId, shell)).ConfigureAwait(false); }
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
        Attach(id, cols, rows);
    }

    /// <summary>Attaches to <paramref name="id"/>, leaving any other session first. False if there is no such session.</summary>
    private bool Attach(string id, int cols, int rows)
    {
        string? before;
        lock (_lock) { before = _attached; _attached = id; }
        if (before != id) Manager.Detach(this);
        lock (_lock) _attached = id;
        try
        {
            var generation = Manager.Attach(id, this, cols, rows);
            lock (_lock) _generation = generation;
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
        List<ShellEnvelope> lines;
        try { lines = await Task.Run(() => ShellReplay.TranscriptLines(id, _gate.Transcripts.Replay(id))).ConfigureAwait(false); }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException) { Fail(ShellError.NoSuchSession, id); return; }
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

    internal void SendSessions(IReadOnlyList<ShellSessionInfo> list) => Send(new ShellEnvelope(ShellEnvelope.Sessions) { SessionList = [.. list] });

    internal void SendState()
    {
        if (_gate.Hooks.State(PhoneId) is { } state) Send(new ShellEnvelope(ShellEnvelope.MacState) { State = state });
    }

    internal void SendHost()
    {
        if (_gate.Hooks.Host(PhoneId) is { } host) Send(new ShellEnvelope(ShellEnvelope.Host) { HostInfo = host });
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

    private void Enqueue(byte[] line, TaskCompletionSource? written)
    {
        if (IsClosed) { written?.TrySetResult(); return; }
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

    private bool IsAttached(string session)
    {
        lock (_lock) return _attached == session;
    }
}
