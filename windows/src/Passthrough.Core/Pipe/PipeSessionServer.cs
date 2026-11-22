using System.Text;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The tray app's end of the pipe (stage 4 plan, section 4): it serves its account's shells to the service, which
/// asks on behalf of phones. Each phone connection the service names (<c>conn</c>) is an attachment here, whose output
/// goes back as frames. A connection whose output backs up past <see cref="ConnBacklogLimit"/> is detached and the
/// service told to close that phone, so one slow phone never holds up the rest or the shells; past the link's own limit
/// (the service isn't reading at all) the link closes.
/// </summary>
public sealed class PipeSessionServer
{
    public const long ConnBacklogLimit = 8 << 20;
    public const long LinkBacklogLimit = 16 << 20;
    /// <summary>Transcript lines go in chunks of about this many bytes.</summary>
    internal const int TranscriptChunk = 256 << 10;

    private readonly LocalSessionHost _host;
    private readonly Func<PipeHostState> _state;
    private readonly Func<ShellError?> _lock;
    private readonly Action<string>? _log;
    private readonly Lock _gate = new();
    private readonly Dictionary<uint, Stub> _stubs = [];
    private PipeLink? _link;

    public PipeSessionServer(LocalSessionHost host, Func<PipeHostState> state, Func<ShellError?> lockScreen, Action<string>? log = null)
    {
        _host = host;
        _state = state;
        _lock = lockScreen;
        _log = log;
        _host.Changed += () => Send(PipeFrame.Json(PipeKind.Sessions, new PipeMessage { Sessions = [.. _host.Sessions] }));
    }

    /// <summary>Keeps a pass a phone handed this account (stage 7); returns an error's wire name, or null when kept.</summary>
    public Func<PipeMessage, Task<string?>>? SavePass { get; set; }

    /// <summary>Frames this end doesn't serve itself (the answers to the tray app's own requests: <see cref="PipeAccessAdmin"/>).</summary>
    public event Action<PipeFrame>? OtherFrame;

    /// <summary>Fires when a link to the service comes (true) or goes (false).</summary>
    public event Action<bool>? LinkChanged;

    /// <summary>Linked to the service now.</summary>
    public bool IsLinked { get { lock (_gate) return _link is not null; } }

    /// <summary>Sends a frame to the service; false when there is no link.</summary>
    public bool SendFrame(PipeFrame frame)
    {
        PipeLink? link;
        lock (_gate) link = _link;
        return link?.Send(frame) ?? false;
    }

    /// <summary>Serves <paramref name="link"/> until it closes: the snapshots first, then the service's requests in order.</summary>
    public async Task ServeAsync(PipeLink link)
    {
        lock (_gate) _link = link;
        LinkChanged?.Invoke(true);
        link.Send(PipeFrame.Json(PipeKind.Sessions, new PipeMessage { Sessions = [.. _host.Sessions] }));
        PushState();
        try { await link.RunAsync(OnFrameAsync).ConfigureAwait(false); }
        finally
        {
            List<Stub> stubs;
            lock (_gate)
            {
                if (ReferenceEquals(_link, link)) _link = null;
                stubs = [.. _stubs.Values];
                _stubs.Clear();
            }
            // The phones went with the link (the service tells them); their sessions keep running.
            foreach (var stub in stubs) _host.Gone(stub);
            LinkChanged?.Invoke(false);
        }
    }

    /// <summary>Sends the service this account's state again (it changed).</summary>
    public void PushState() => Send(PipeFrame.Json(PipeKind.HostState, new PipeMessage { State = _state() }));

    private void Send(PipeFrame frame)
    {
        PipeLink? link;
        lock (_gate) link = _link;
        link?.Send(frame);
    }

    private Stub StubFor(uint conn)
    {
        lock (_gate)
        {
            if (!_stubs.TryGetValue(conn, out var stub)) _stubs[conn] = stub = new Stub(this, conn);
            return stub;
        }
    }

    private Stub? Existing(uint? conn)
    {
        if (conn is not { } c) return null;
        lock (_gate) return _stubs.TryGetValue(c, out var stub) ? stub : null;
    }

    private void Reply(PipeMessage message) => Send(PipeFrame.Json(PipeKind.Reply, message));

    private void Fail(uint? id, ShellError error, string? message = null) => Reply(new PipeMessage { Id = id, Error = error.ToWire(), Message = message });

    private ValueTask OnFrameAsync(PipeFrame frame)
    {
        if (frame.Kind == PipeKind.Input)
        {
            if (frame.ReadData() is { } data) _host.Input(data.Session, data.Data.ToArray(), StubFor(data.Conn));
            return ValueTask.CompletedTask;
        }
        if (frame.Kind is PipeKind.AdminReply or PipeKind.AdminEvent)
        {
            OtherFrame?.Invoke(frame);
            return ValueTask.CompletedTask;
        }
        if (frame.Kind is not (PipeKind.Open or PipeKind.Attach or PipeKind.Detach or PipeKind.Resize or PipeKind.Close or PipeKind.SetViewing
            or PipeKind.History or PipeKind.Transcript or PipeKind.Lock or PipeKind.SavePass or PipeKind.ConnClosed or PipeKind.PhoneGone))
            return ValueTask.CompletedTask; // a kind this build doesn't know
        if (frame.Read<PipeMessage>() is not { } m) return ValueTask.CompletedTask;
        switch (frame.Kind)
        {
            case PipeKind.Open:
                // A shell starting must not hold up anything else on the pipe; the service waits for this answer
                // before it sends that phone anything more.
                if (m.Phone is not { } phone || m.Cols is not { } cols || m.Rows is not { } rows) { Fail(m.Id, ShellError.BadRequest); break; }
                _ = OpenAsync(m.Id, m.Label ?? "A phone", cols, rows, phone, m.Shell);
                break;
            case PipeKind.Attach:
                if (m.Conn is not { } conn || m.Session is not { } session || m.Cols is not { } c || m.Rows is not { } r || m.Generation is not { } g)
                { Fail(m.Id, ShellError.BadRequest); break; }
                try
                {
                    var stub = StubFor(conn);
                    stub.Revive();
                    _host.AttachAsync(session, stub, c, r, g).GetAwaiter().GetResult();
                    Reply(new PipeMessage { Id = m.Id, Generation = g });
                }
                catch (ShellException e) { Fail(m.Id, e.Error); }
                break;
            case PipeKind.Detach:
                if (Existing(m.Conn) is { } detaching) _host.Detach(detaching);
                break;
            case PipeKind.Resize:
                if (m.Session is { } rs && m.Cols is { } rc && m.Rows is { } rr && m.Conn is { } rconn) _host.Resize(rs, rc, rr, StubFor(rconn));
                break;
            case PipeKind.Close:
                if (m.Session is { } closing) _host.Close(closing);
                break;
            case PipeKind.SetViewing:
                if (m.Conn is { } vconn && m.On is { } on)
                {
                    var viewer = StubFor(vconn);
                    viewer.Looking = on;
                    _host.SetViewing(viewer, on);
                }
                break;
            case PipeKind.History:
                _ = HistoryAsync(m.Id);
                break;
            case PipeKind.Transcript:
                _ = TranscriptAsync(m.Id, m.Session);
                break;
            case PipeKind.Lock:
                _lock();
                break;
            case PipeKind.SavePass:
                _ = SavePassAsync(m);
                break;
            case PipeKind.ConnClosed:
                if (m.Conn is { } closed)
                {
                    Stub? stub;
                    lock (_gate) _stubs.Remove(closed, out stub);
                    if (stub is not null) _host.Gone(stub);
                }
                break;
            case PipeKind.PhoneGone:
                if (m.Phone is { } revoked) _host.CloseSessions(revoked);
                break;
        }
        return ValueTask.CompletedTask;
    }

    private async Task OpenAsync(uint? id, string label, int cols, int rows, string phone, string? shell)
    {
        try { Reply(new PipeMessage { Id = id, Session = await _host.OpenAsync(label, cols, rows, phone, shell).ConfigureAwait(false) }); }
        catch (ShellException e) { Fail(id, e.Error, e.Error == ShellError.BadRequest ? null : e.Message); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or ArgumentException)
        {
            _log?.Invoke($"shell: a shell could not start ({e.GetType().Name})");
            Fail(id, ShellError.BadRequest);
        }
    }

    private async Task SavePassAsync(PipeMessage m)
    {
        var error = SavePass is { } save ? await save(m).ConfigureAwait(false) : ShellError.PassNotSaved.ToWire();
        Reply(new PipeMessage { Id = m.Id, Error = error });
    }

    private async Task HistoryAsync(uint? id)
    {
        try { Reply(new PipeMessage { Id = id, History = [.. await _host.HistoryAsync().ConfigureAwait(false)] }); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Reply(new PipeMessage { Id = id, History = [] }); }
    }

    private async Task TranscriptAsync(uint? id, string? session)
    {
        IReadOnlyList<ShellEnvelope> lines;
        try
        {
            if (session is null || !Guid.TryParseExact(session, "D", out _)) throw new ShellException(ShellError.NoSuchSession);
            lines = await _host.TranscriptAsync(session).ConfigureAwait(false);
        }
        catch (ShellException e)
        {
            Send(PipeFrame.Json(PipeKind.TranscriptChunk, new PipeMessage { Id = id, Error = e.Error.ToWire(), Last = true }));
            return;
        }
        var chunk = new List<string>();
        var size = 0;
        foreach (var line in lines)
        {
            var text = Encoding.UTF8.GetString(line.EncodeLine()).TrimEnd('\n');
            if (size + text.Length > TranscriptChunk && chunk.Count > 0)
            {
                Send(PipeFrame.Json(PipeKind.TranscriptChunk, new PipeMessage { Id = id, Lines = chunk }));
                chunk = [];
                size = 0;
            }
            chunk.Add(text);
            size += text.Length;
        }
        Send(PipeFrame.Json(PipeKind.TranscriptChunk, new PipeMessage { Id = id, Lines = chunk, Last = true }));
    }

    /// <summary>One phone connection as the session manager sees it: what it sends goes to the service as frames.</summary>
    private sealed class Stub(PipeSessionServer server, uint conn) : IShellAttachment
    {
        private long _queued;
        private volatile bool _dropped;
        public volatile bool Looking;

        public bool IsLooking => Looking;

        /// <summary>A new attach after a drop: the service closed that phone; a new one may reuse nothing, but be safe.</summary>
        public void Revive() => _dropped = false;

        private void Send(PipeFrame frame)
        {
            if (_dropped) return;
            var link = server._link;
            if (link is null) return;
            var size = frame.Payload.Length + PipeFrame.HeaderLength;
            if (Interlocked.Add(ref _queued, size) > ConnBacklogLimit)
            {
                Interlocked.Add(ref _queued, -size);
                Drop();
                return;
            }
            link.Send(frame, written => Interlocked.Add(ref _queued, -written));
        }

        private void Drop()
        {
            _dropped = true;
            server._host.Detach(this);
            server._log?.Invoke("pipe: a phone's output backed up; the service was told to close it");
            server.Send(PipeFrame.Json(PipeKind.DropConn, new PipeMessage { Conn = conn }));
        }

        private PipeMessage Notice(string session) => new() { Conn = conn, Session = session };

        public void ShellOutput(byte[] data, string session)
        {
            for (var offset = 0; offset < data.Length; offset += RemoteShell.OutputChunk)
                Send(PipeFrame.Data(PipeKind.Output, conn, session, data.AsSpan(offset, Math.Min(RemoteShell.OutputChunk, data.Length - offset))));
        }

        public void ShellEnded(string session, int exitStatus) => Send(PipeFrame.Json(PipeKind.Ended, Notice(session) with { ExitStatus = exitStatus }));

        public void ShellDetached(string session, ulong generation) => Send(PipeFrame.Json(PipeKind.Detached, Notice(session) with { Generation = generation }));

        public void ShellReplaying(string session) => Send(PipeFrame.Json(PipeKind.Replaying, Notice(session)));

        public void ShellReplayed(string session) => Send(PipeFrame.Json(PipeKind.Replayed, Notice(session)));
    }
}
