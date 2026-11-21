using System.Text;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The service's view of one Windows account's shells (stage 4 plan, section 4): an <see cref="ISessionHost"/> whose
/// sessions live in that account's tray app, across the pipe. While no tray app is linked, every request a phone makes
/// of the shells is answered <c>signed_out</c> and the session list is empty. When the link goes, every phone attached
/// to a session is told it was detached, then the empty list goes out.
/// </summary>
public sealed class PipeSessionHost : ISessionHost
{
    public static readonly TimeSpan OpenLimit = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan ReplyLimit = TimeSpan.FromSeconds(5);
    private const int TimeoutsBeforeDrop = 3;

    private readonly Lock _lock = new();
    private readonly Dictionary<IShellAttachment, uint> _conns = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<uint, Conn> _byConn = [];
    private readonly Dictionary<uint, Pending> _pending = [];
    private readonly TimeProvider _time;
    private readonly Action<string>? _log;
    private PipeLink? _link;
    private IReadOnlyList<ShellSessionInfo> _sessions = [];
    private PipeHostState? _state;
    private uint _nextConn;
    private uint _nextId;
    private int _timeouts;

    private sealed class Conn(IShellAttachment client)
    {
        public readonly IShellAttachment Client = client;
        public string? Session;
        public ulong Generation;
    }

    private sealed class Pending
    {
        public readonly TaskCompletionSource<PipeMessage> Reply = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<string>? Lines;
    }

    public PipeSessionHost(string account, TimeProvider? time = null, Action<string>? log = null)
    {
        Account = account;
        _time = time ?? TimeProvider.System;
        _log = log;
    }

    /// <summary>The Windows account (SID) whose shells these are.</summary>
    public string Account { get; }

    public IReadOnlyList<ShellSessionInfo> Sessions { get { lock (_lock) return _sessions; } }

    public event Action? Changed;

    /// <summary>Fires when the tray app says something new about its side (<see cref="State"/>), or goes.</summary>
    public event Action? StateChanged;

    public bool IsAvailable { get { lock (_lock) return _link is not null; } }

    /// <summary>What the tray app last said about its side; null while none is linked.</summary>
    public PipeHostState? State { get { lock (_lock) return _state; } }

    // MARK: The link

    /// <summary>The account's tray app is here; whatever was linked before is let go first.</summary>
    public void Link(PipeLink link)
    {
        PipeLink? before;
        lock (_lock) { before = _link; }
        if (before is not null) Unlink(before);
        lock (_lock) _link = link;
        _log?.Invoke("pipe: a tray app linked");
        Changed?.Invoke();
    }

    /// <summary>The tray app went (quit, crashed, signed out): pending requests fail, attached phones are told, the list empties.</summary>
    public void Unlink(PipeLink link)
    {
        List<Pending> pending;
        List<(IShellAttachment Client, string Session, ulong Generation)> attached;
        lock (_lock)
        {
            if (!ReferenceEquals(_link, link)) return;
            _link = null;
            pending = [.. _pending.Values];
            _pending.Clear();
            attached = [.. _byConn.Values.Where(c => c.Session is not null).Select(c => (c.Client, c.Session!, c.Generation))];
            foreach (var conn in _byConn.Values) conn.Session = null;
            _sessions = [];
            _state = null;
            _timeouts = 0;
        }
        link.Close();
        foreach (var p in pending) p.Reply.TrySetException(new ShellException(ShellError.SignedOut));
        foreach (var (client, session, generation) in attached) client.ShellDetached(session, generation);
        _log?.Invoke("pipe: the tray app went");
        Changed?.Invoke();
        StateChanged?.Invoke();
    }

    /// <summary>Handles a frame from the tray app (its link's reader, in order).</summary>
    public ValueTask OnFrameAsync(PipeFrame frame)
    {
        switch (frame.Kind)
        {
            case PipeKind.Output:
                if (frame.ReadData() is { } data && Client(data.Conn) is { } client) client.ShellOutput(data.Data.ToArray(), data.Session);
                break;
            case PipeKind.Reply:
                Answer(frame.Read<PipeMessage>());
                break;
            case PipeKind.Sessions:
                if (frame.Read<PipeMessage>() is { Sessions: { } list })
                {
                    lock (_lock) _sessions = list;
                    Changed?.Invoke();
                }
                break;
            case PipeKind.HostState:
                if (frame.Read<PipeMessage>() is { State: { } state })
                {
                    lock (_lock) _state = state;
                    StateChanged?.Invoke();
                }
                break;
            case PipeKind.Replaying:
                if (Notice(frame) is ({ } c, { } s, _)) c.ShellReplaying(s);
                break;
            case PipeKind.Replayed:
                if (Notice(frame) is ({ } c2, { } s2, _)) c2.ShellReplayed(s2);
                break;
            case PipeKind.Ended:
                if (Notice(frame) is ({ } c3, { } s3, { } m3))
                {
                    Forget(m3.Conn!.Value, s3);
                    c3.ShellEnded(s3, m3.ExitStatus ?? -1);
                }
                break;
            case PipeKind.Detached:
                if (frame.Read<PipeMessage>() is { Conn: { } dc, Session: { } ds, Generation: { } dg } && Client(dc) is { } c4)
                {
                    ForgetIf(dc, ds, dg);
                    c4.ShellDetached(ds, dg);
                }
                break;
            case PipeKind.TranscriptChunk:
                Chunk(frame.Read<PipeMessage>());
                break;
            case PipeKind.DropConn:
                if (frame.Read<PipeMessage>() is { Conn: { } dropped } && Client(dropped) is { } gone) gone.ShellDropped();
                break;
        }
        return ValueTask.CompletedTask;
    }

    private (IShellAttachment?, string?, PipeMessage?) Notice(PipeFrame frame) =>
        frame.Read<PipeMessage>() is { Conn: { } conn, Session: { } session } message && Client(conn) is { } client ? (client, session, message) : (null, null, null);

    private void Forget(uint conn, string session)
    {
        lock (_lock) if (_byConn.TryGetValue(conn, out var c) && c.Session == session) c.Session = null;
    }

    /// <summary>A takeover notice is for the attach it names only (the connection checks the generation itself too).</summary>
    private void ForgetIf(uint conn, string session, ulong generation)
    {
        lock (_lock) if (_byConn.TryGetValue(conn, out var c) && c.Session == session && c.Generation == generation) c.Session = null;
    }

    private IShellAttachment? Client(uint conn)
    {
        lock (_lock) return _byConn.TryGetValue(conn, out var c) ? c.Client : null;
    }

    private uint ConnOf(IShellAttachment client)
    {
        lock (_lock)
        {
            if (_conns.TryGetValue(client, out var conn)) return conn;
            conn = ++_nextConn;
            _conns[client] = conn;
            _byConn[conn] = new Conn(client);
            return conn;
        }
    }

    // MARK: Requests

    private Task<PipeMessage> AskAsync(byte kind, Func<uint, PipeMessage> message, TimeSpan limit)
    {
        PipeLink? link;
        uint id;
        var pending = new Pending();
        lock (_lock)
        {
            link = _link;
            if (link is null) throw new ShellException(ShellError.SignedOut);
            id = ++_nextId;
            _pending[id] = pending;
        }
        if (!link.Send(PipeFrame.Json(kind, message(id))))
        {
            lock (_lock) _pending.Remove(id);
            throw new ShellException(ShellError.SignedOut);
        }
        return WaitAsync(id, pending, link, limit);
    }

    private async Task<PipeMessage> WaitAsync(uint id, Pending pending, PipeLink link, TimeSpan limit)
    {
        try
        {
            var reply = await pending.Reply.Task.WaitAsync(limit, _time).ConfigureAwait(false);
            lock (_lock) _timeouts = 0;
            if (reply.Error is { } error) throw new ShellException(Wire(error, ShellError.BadRequest), reply.Message);
            return reply;
        }
        catch (TimeoutException)
        {
            bool drop;
            lock (_lock)
            {
                _pending.Remove(id);
                drop = ++_timeouts >= TimeoutsBeforeDrop;
            }
            _log?.Invoke("pipe: the tray app didn't answer in time");
            if (drop) Unlink(link);
            throw new ShellException(ShellError.BadRequest);
        }
    }

    private void Answer(PipeMessage? reply)
    {
        if (reply?.Id is not { } id) return;
        Pending? pending;
        lock (_lock)
        {
            if (!_pending.Remove(id, out pending)) return;
        }
        pending.Reply.TrySetResult(reply);
    }

    private void Chunk(PipeMessage? chunk)
    {
        if (chunk?.Id is not { } id) return;
        Pending? pending;
        lock (_lock)
        {
            if (!_pending.TryGetValue(id, out pending)) return;
            (pending.Lines ??= []).AddRange(chunk.Lines ?? []);
            if (chunk.Last != true && chunk.Error is null) return;
            _pending.Remove(id);
        }
        pending.Reply.TrySetResult(chunk with { Lines = pending.Lines });
    }

    private void Tell(byte kind, PipeMessage message)
    {
        PipeLink? link;
        lock (_lock) link = _link;
        link?.Send(PipeFrame.Json(kind, message));
    }

    // MARK: ISessionHost

    public async Task<string> OpenAsync(string label, int cols, int rows, string phoneId, string? shell)
    {
        var reply = await AskAsync(PipeKind.Open, id => new PipeMessage { Id = id, Phone = phoneId, Label = label, Shell = shell, Cols = cols, Rows = rows }, OpenLimit)
            .ConfigureAwait(false);
        return reply.Session ?? throw new ShellException(ShellError.BadRequest);
    }

    public async Task AttachAsync(string session, IShellAttachment client, int cols, int rows, ulong generation)
    {
        var conn = ConnOf(client);
        lock (_lock)
        {
            // Known before the answer: a takeover notice for this attach may come first.
            var c = _byConn[conn];
            c.Session = session;
            c.Generation = generation;
        }
        try
        {
            await AskAsync(PipeKind.Attach, id => new PipeMessage { Id = id, Conn = conn, Session = session, Cols = cols, Rows = rows, Generation = generation }, ReplyLimit)
                .ConfigureAwait(false);
        }
        catch (ShellException)
        {
            Forget(conn, session);
            throw;
        }
    }

    public void Detach(IShellAttachment client)
    {
        uint conn;
        lock (_lock)
        {
            if (!_conns.TryGetValue(client, out conn)) return;
            _byConn[conn].Session = null;
        }
        Tell(PipeKind.Detach, new PipeMessage { Conn = conn });
    }

    public void Gone(IShellAttachment client)
    {
        uint conn;
        lock (_lock)
        {
            if (!_conns.Remove(client, out conn)) return;
            _byConn.Remove(conn);
        }
        Tell(PipeKind.ConnClosed, new PipeMessage { Conn = conn });
    }

    public void SetViewing(IShellAttachment client, bool on) => Tell(PipeKind.SetViewing, new PipeMessage { Conn = ConnOf(client), On = on });

    public void Input(string session, byte[] input, IShellAttachment client)
    {
        var conn = ConnOf(client);
        PipeLink? link;
        lock (_lock) link = _link;
        for (var offset = 0; offset < input.Length; offset += PipeFrame.MaxPayload - 512)
            link?.Send(PipeFrame.Data(PipeKind.Input, conn, session, input.AsSpan(offset, Math.Min(PipeFrame.MaxPayload - 512, input.Length - offset))));
    }

    public void Resize(string session, int cols, int rows, IShellAttachment client) =>
        Tell(PipeKind.Resize, new PipeMessage { Conn = ConnOf(client), Session = session, Cols = cols, Rows = rows });

    public void Close(string session) => Tell(PipeKind.Close, new PipeMessage { Session = session });

    public void CloseSessions(string phoneId) => Tell(PipeKind.PhoneGone, new PipeMessage { Phone = phoneId });

    public async Task<IReadOnlyList<ShellHistoryEntry>> HistoryAsync() =>
        (await AskAsync(PipeKind.History, id => new PipeMessage { Id = id }, ReplyLimit).ConfigureAwait(false)).History ?? [];

    public async Task<IReadOnlyList<ShellEnvelope>> TranscriptAsync(string session)
    {
        var reply = await AskAsync(PipeKind.Transcript, id => new PipeMessage { Id = id, Session = session }, ReplyLimit).ConfigureAwait(false);
        if (reply.Error is { } error) throw new ShellException(Wire(error, ShellError.NoSuchSession));
        var lines = new List<ShellEnvelope>();
        foreach (var line in reply.Lines ?? [])
        {
            try { lines.Add(ShellEnvelope.Decode(Encoding.UTF8.GetBytes(line))); }
            catch (Protocol.ProtocolException) { throw new ShellException(ShellError.NoSuchSession); }
        }
        return lines;
    }

    private static ShellError Wire(string error, ShellError otherwise) => ShellErrorWire.IsKnown(error) ? ShellErrorWire.Parse(error) : otherwise;

    /// <summary>Asks the tray app to lock its Windows session; null when asked, else why not.</summary>
    public ShellError? Lock()
    {
        if (!IsAvailable) return ShellError.SignedOut;
        Tell(PipeKind.Lock, new PipeMessage { Id = 0 });
        return null;
    }
}
