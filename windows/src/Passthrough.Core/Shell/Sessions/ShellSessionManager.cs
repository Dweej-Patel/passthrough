using System.Globalization;
using System.Text;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// The host's interactive shell sessions (a port of ShellSessionManager.swift, the phone side of it). They keep running
/// while nothing is attached; a client that attaches is replayed the recent output, and a later attach takes the session
/// over. Terminal windows on the host itself showing a session beside a phone come with stage 7 (computers), with the
/// colours they tell.
/// </summary>
public sealed class ShellSessionManager
{
    private const int TitleLimit = 60;
    /// <summary>How much output after a typed line's return may still carry its echo.</summary>
    private const int EchoWindow = 2048;
    private const int TypedLimit = 512;
    private const int TailBytes = 4096;
    private static readonly TimeSpan CloseTimeout = TimeSpan.FromSeconds(5);
    /// <summary>How long a redraw leaves the terminal shorter: long enough for the program to read the size while it is different.</summary>
    internal static readonly TimeSpan RedrawPause = TimeSpan.FromMilliseconds(250);

    private enum InputEscape { None, Escape, Csi, Ss3 }

    private readonly record struct Size(int Cols, int Rows);

    private sealed class Session(string id, DateTimeOffset startedAt, string? openedBy, string shell, IPty pty, TranscriptWriter writer, Size size)
    {
        public readonly string Id = id;
        public readonly DateTimeOffset StartedAt = startedAt;
        /// <summary>The phone that opened it, so revoking that phone ends it; any authorized phone may still attach meanwhile.</summary>
        public readonly string? OpenedBy = openedBy;
        public readonly string Shell = shell;
        public readonly IPty Pty = pty;
        public readonly TranscriptWriter Writer = writer;
        public readonly ScrollbackBuffer Scrollback = new(RemoteShell.ScrollbackBytes);
        public string Title = "~";
        /// <summary>The line being typed, until the title is known.</summary>
        public List<byte> Typed = [];
        public bool TitleKnown;
        /// <summary>Output bytes received so far, to find what arrived since a point.</summary>
        public long OutputCount;
        /// <summary><see cref="OutputCount"/> when the line in <see cref="Typed"/> started.</summary>
        public long? LineStart;
        public InputEscape InputEscape;
        /// <summary>A typed line waiting to be seen echoed before it becomes the title.</summary>
        public (string Text, long From, long Until)? PendingTitle;
        public DateTimeOffset LastOutputAt = startedAt;
        /// <summary>The last few KB of output since the last input, read for a question once it goes quiet.</summary>
        public byte[] Tail = [];
        /// <summary>The question it seems to be waiting on; null once input answers it.</summary>
        public string? Waiting;
        public readonly ProgramStatus ProgramStatus = new();
        public ShellStatus? Status;
        /// <summary>What was in front when the program first reported: once it is gone, so is everything it said.</summary>
        public long? StatusOwner;
        public bool Redrawing;
        public bool CheckedSinceOutput = true;
        public bool LookScheduled;
        public int? ExitStatus;
        public bool Running = true;
        public IShellAttachment? Attachment;
        /// <summary>What <see cref="Attach"/> returned for <see cref="Attachment"/>.</summary>
        public ulong Generation;
        /// <summary>Whoever attached or typed last: the terminal's size follows it.</summary>
        public IShellAttachment? Active;
        public Size Size = size;

        /// <summary>The question it waits on: what the program says when it reports its status, else what its screen seems to ask.</summary>
        public string? Question => Status is null ? Waiting : Status.IsBlocked ? Status.Message ?? "Needs you" : null;

        public ShellSessionInfo Info => new()
        {
            Id = Id, Title = Title, StartedAt = TranscriptStore.Seconds(StartedAt), LastOutputAt = TranscriptStore.Seconds(LastOutputAt),
            Running = Running, ExitStatus = ExitStatus, Waiting = Running ? Question : null, Status = Running ? Status : null, Shell = Shell,
        };
    }

    private readonly TranscriptStore _transcripts;
    private readonly Func<string?, ShellCommand> _command;
    private readonly Func<PtyStart, IPty> _startPty;
    private readonly Func<IReadOnlyDictionary<string, string>> _environment;
    private readonly string _directory;
    private readonly TimeSpan _endedRetention;
    /// <summary>How long output must stay quiet before the last lines are read for a question.</summary>
    private readonly TimeSpan _quietBeforeAsking;
    private readonly TimeProvider _time;
    private readonly Action<string>? _log;

    /// <summary>Guards everything below.</summary>
    private readonly Lock _lock = new();
    private readonly Callouts _callouts = new();
    private readonly Dictionary<string, Session> _table = [];
    private readonly List<string> _order = [];
    /// <summary>Sessions <see cref="Open"/> is starting outside the lock, counted toward the cap.</summary>
    private int _opening;
    private ulong _lastGeneration;
    private readonly HashSet<ITimer> _timers = [];

    /// <summary>Fires after the session list changes, off the lock, in order.</summary>
    public event Action? Changed;

    /// <summary>
    /// Fires as a session's status changes in a way anyone shows, and as it ends, with the session as it is then and
    /// whether someone is looking at it. Off the lock, in order.
    /// </summary>
    public event Action<ShellSessionInfo, bool>? StatusChanged;

    /// <param name="command">The catalog: the shell for an id from <c>open</c> (null: the default). Throws <see cref="ShellException"/> for one it doesn't have.</param>
    /// <param name="startPty">Starts a pseudo-terminal (ConPTY on Windows).</param>
    /// <param name="environment">The session's environment, built fresh each time (never this process's own).</param>
    public ShellSessionManager(
        TranscriptStore transcripts,
        Func<string?, ShellCommand> command,
        Func<PtyStart, IPty> startPty,
        Func<IReadOnlyDictionary<string, string>> environment,
        string directory,
        TimeSpan? endedRetention = null,
        TimeSpan? quietBeforeAsking = null,
        TimeProvider? time = null,
        Action<string>? log = null)
    {
        _transcripts = transcripts;
        _command = command;
        _startPty = startPty;
        _environment = environment;
        _directory = directory;
        _endedRetention = endedRetention ?? TimeSpan.FromMinutes(10);
        _quietBeforeAsking = quietBeforeAsking ?? TimeSpan.FromSeconds(1.5);
        _time = time ?? TimeProvider.System;
        _log = log;
    }

    public List<ShellSessionInfo> Sessions
    {
        get { lock (_lock) return [.. _order.Select(id => _table[id].Info)]; }
    }

    /// <summary>How many running sessions <paramref name="phoneId"/> opened (what its Stop would end).</summary>
    public int RunningSessions(string phoneId)
    {
        lock (_lock) return _table.Values.Count(s => s.Running && s.OpenedBy == phoneId);
    }

    /// <summary>
    /// Starts a shell. The spawn and the transcript's first write happen outside the lock, so listing or using other
    /// sessions never waits on them; a slot is held meanwhile so the cap still holds. <paramref name="phoneId"/> is the
    /// phone opening it (<see cref="CloseSessions"/>); <paramref name="shell"/> a catalog id, or null for the default.
    /// </summary>
    public string Open(string phoneLabel, int cols, int rows, string? phoneId = null, string? shell = null)
    {
        lock (_lock)
        {
            // Ended ones make room.
            foreach (var ended in _order.Where(id => !_table[id].Running).ToList()) Remove(ended);
            if (_table.Values.Count(s => s.Running) + _opening >= RemoteShell.MaxSessions) throw new ShellException(ShellError.TooManySessions);
            _opening++;
        }
        var reserved = true;
        try
        {
            var command = _command(shell);
            var id = Guid.NewGuid().ToString().ToUpperInvariant();
            var now = _time.GetUtcNow();
            // Every session says it is one, so a shell started inside it never asks for another.
            var environment = new Dictionary<string, string>(_environment(), StringComparer.OrdinalIgnoreCase)
            {
                [RemoteShell.SessionVariable] = id,
            };
            var size = new Size(Dimension(cols), Dimension(rows));
            var pty = _startPty(new PtyStart(command.Executable, command.Arguments, _directory, environment, size.Cols, size.Rows));
            TranscriptWriter writer;
            try { writer = _transcripts.Begin(id, "~", phoneLabel, cols, rows, now); }
            catch
            {
                pty.Dispose(); // never started
                throw;
            }
            var session = new Session(id, now, phoneId, command.Id, pty, writer, size);
            pty.OnOutput = data => { lock (_lock) Received(data, session); };
            pty.OnExit = status => { lock (_lock) Ended(session, status); };
            lock (_lock)
            {
                _opening--;
                reserved = false;
                _table[id] = session;
                _order.Add(id);
                try { pty.Start(); }
                catch
                {
                    Remove(id);
                    writer.Finish(null, now);
                    ThreadPool.UnsafeQueueUserWorkItem(_ => pty.Dispose(), null);
                    throw;
                }
                _log?.Invoke("shell: opened session");
                NotifyChange();
            }
            return id;
        }
        finally
        {
            if (reserved) lock (_lock) _opening--;
        }
    }

    /// <summary>
    /// Replays the scrollback to <paramref name="client"/>, then streams live output to it. A client attached earlier is
    /// told it was detached, with the generation its own attach returned. The terminal takes this client's size.
    /// Returns this attach's generation, unique per manager.
    /// </summary>
    public ulong Attach(string id, IShellAttachment client, int cols, int rows)
    {
        lock (_lock)
        {
            if (!_table.TryGetValue(id, out var session)) throw new ShellException(ShellError.NoSuchSession);
            var generation = ++_lastGeneration;
            var size = new Size(Dimension(cols), Dimension(rows));
            if (session.Attachment is { } previous && !ReferenceEquals(previous, client))
            {
                var old = session.Generation;
                _callouts.Post(() => previous.ShellDetached(id, old));
            }
            var sizeBefore = session.Size;
            if (session.Running)
            {
                session.Active = client;
                Resize(session, size);
            }
            var replay = session.Scrollback.Replay();
            // A full-screen program replayed from partway: what it drew before the cut isn't in the replay, so have it
            // draw its screen again, unless taking this client's size already does.
            if (session.Running && size == sizeBefore && session.Scrollback.IsPartial && session.Scrollback.Modes.IsAlternateScreen)
                Redraw(session);
            _callouts.Post(() => client.ShellReplaying(id));
            for (var offset = 0; offset < replay.Length; offset += RemoteShell.OutputChunk)
            {
                var chunk = replay[offset..Math.Min(offset + RemoteShell.OutputChunk, replay.Length)];
                _callouts.Post(() => client.ShellOutput(chunk, id));
            }
            _callouts.Post(() => client.ShellReplayed(id));
            if (session.Running && client.IsLooking) MarkResultSeen(session);
            if (session.Running)
            {
                session.Attachment = client;
                session.Generation = generation;
            }
            else if (session.ExitStatus is { } status)
            {
                _callouts.Post(() => client.ShellEnded(id, status));
            }
            return generation;
        }
    }

    /// <summary>Stops sending to <paramref name="client"/> without telling it.</summary>
    public void Detach(IShellAttachment client)
    {
        lock (_lock)
        {
            foreach (var session in _table.Values)
            {
                if (ReferenceEquals(session.Attachment, client)) session.Attachment = null;
                if (ReferenceEquals(session.Active, client)) session.Active = null;
            }
        }
    }

    /// <summary><paramref name="client"/> (a phone) has its terminal on screen now: a result waiting in what it shows is seen.</summary>
    public void LookedAt(IShellAttachment client)
    {
        lock (_lock)
            foreach (var session in _table.Values.Where(s => ReferenceEquals(s.Attachment, client))) MarkResultSeen(session);
    }

    /// <summary>
    /// Typing. <paramref name="client"/> is who typed it, when known: the terminal takes that client's size if it isn't
    /// already the one it follows. What a terminal sends by itself (its answers to a program's questions, focus in and
    /// out) is not typing: it never moves the session, and from a terminal the session doesn't follow it is dropped.
    /// </summary>
    public void Input(string id, ReadOnlySpan<byte> input, IShellAttachment? client = null)
    {
        lock (_lock)
        {
            if (!_table.TryGetValue(id, out var session) || !session.Running) return;
            var data = TerminalReports.RemovingProgramStatusReplies(input);
            var typed = TerminalReports.Removing(data);
            if (client is not null)
            {
                var followed = session.Active is null || ReferenceEquals(session.Active, client);
                if (!followed) data = typed;
                if (typed.Length > 0 && !followed && ReferenceEquals(session.Attachment, client)) session.Active = client;
            }
            if (data.Length == 0) return;
            session.Pty.Write(data);
            // A terminal's answers alone: nobody typed, so nothing was answered either.
            if (typed.Length == 0) return;
            MarkResultSeen(session);
            if (!session.TitleKnown) LearnTitle(typed, session);
            // Someone answered: it isn't waiting any more, and only what comes next can ask again.
            session.Tail = [];
            if (session.Waiting is not null)
            {
                session.Waiting = null;
                NotifyChange();
            }
        }
    }

    /// <summary>
    /// <paramref name="client"/>'s terminal changed size; the session's terminal takes it only while that client is the
    /// one it follows.
    /// </summary>
    public void Resize(string id, int cols, int rows, IShellAttachment? client = null)
    {
        lock (_lock)
        {
            if (!_table.TryGetValue(id, out var session) || !session.Running) return;
            if (client is not null && session.Active is not null && !ReferenceEquals(session.Active, client)) return;
            Resize(session, new Size(Dimension(cols), Dimension(rows)));
        }
    }

    /// <summary>Ends the session's shell; it ends through the normal exit path.</summary>
    public void Close(string id)
    {
        IPty? pty;
        lock (_lock) pty = _table.TryGetValue(id, out var s) && s.Running ? s.Pty : null;
        pty?.Terminate();
    }

    /// <summary>Ends every running session <paramref name="phoneId"/> opened (it was revoked); sessions other phones opened stay.</summary>
    public void CloseSessions(string phoneId)
    {
        List<IPty> ptys;
        lock (_lock) ptys = [.. _table.Values.Where(s => s.Running && s.OpenedBy == phoneId).Select(s => s.Pty)];
        ptys.ForEach(p => p.Terminate());
    }

    /// <summary>Ends every session and returns once their transcripts are finished (or after a few seconds, if one won't end).</summary>
    public void CloseAll()
    {
        List<IPty> ptys;
        lock (_lock) ptys = [.. _table.Values.Where(s => s.Running).Select(s => s.Pty)];
        ptys.ForEach(p => p.Terminate());
        var deadline = DateTime.UtcNow + CloseTimeout;
        while (DateTime.UtcNow < deadline)
        {
            lock (_lock) if (!_table.Values.Any(s => s.Running)) break;
            Thread.Sleep(10);
        }
        lock (_lock)
        {
            foreach (var timer in _timers) timer.Dispose();
            _timers.Clear();
        }
    }

    // For tests.
    internal void SuspendCallouts() => _callouts.Suspend();
    internal void ResumeCallouts() => _callouts.Resume();
    internal void FlushCallouts() => _callouts.Flush(TimeSpan.FromSeconds(5));
    internal ulong? AttachmentGeneration(string id) { lock (_lock) return _table.TryGetValue(id, out var s) && s.Attachment is not null ? s.Generation : null; }

    // Under _lock from here on.

    /// <summary>Resizes the pseudo-terminal, and records the size so a replay draws what follows at it.</summary>
    private void Resize(Session session, Size size)
    {
        if (size == session.Size) return;
        session.Size = size;
        session.Pty.Resize(size.Cols, size.Rows);
        session.Writer.Resize(size.Cols, size.Rows, _time.GetUtcNow());
    }

    /// <summary>
    /// Has the program draw its whole screen again. Programs do that when the size changes, and only then, so the
    /// terminal is one row shorter for a moment.
    /// </summary>
    private void Redraw(Session session)
    {
        // One at a time: a second would take the shorter size for the real one.
        if (session.Redrawing || session.Size.Rows <= 1) return;
        var size = session.Size;
        var shorter = size with { Rows = size.Rows - 1 };
        session.Redrawing = true;
        Resize(session, shorter);
        After(RedrawPause, () =>
        {
            session.Redrawing = false;
            // Unless someone's terminal changed size meanwhile: that size stands.
            if (session.Running && session.Size == shorter) Resize(session, size);
        });
    }

    private void Received(byte[] data, Session session)
    {
        if (!session.Running) return;
        var now = _time.GetUtcNow();
        session.Scrollback.Append(data);
        session.OutputCount += data.Length;
        session.Writer.Append(data, now);
        session.LastOutputAt = now;
        if (session.PendingTitle is not null) AdoptEchoedTitle(session);
        ReadStatus(data, session, now);
        NoteOutput(data, session);
        if (!_table.TryGetValue(session.Id, out var current) || current != session) return;
        if (session.Attachment is { } client)
        {
            var id = session.Id;
            _callouts.Post(() => client.ShellOutput(data, id));
        }
    }

    /// <summary>Keeps the tail and looks for a question once the output has been quiet for a while.</summary>
    private void NoteOutput(byte[] data, Session session)
    {
        var joined = new byte[session.Tail.Length + data.Length];
        session.Tail.CopyTo(joined, 0);
        data.CopyTo(joined, session.Tail.Length);
        session.Tail = joined.Length > TailBytes ? joined[^TailBytes..] : joined;
        session.CheckedSinceOutput = false;
        ScheduleLook(session, _quietBeforeAsking);
    }

    /// <summary>One pending look per session, however much output streams in: when it fires early it waits out the rest.</summary>
    private void ScheduleLook(Session session, TimeSpan delay)
    {
        if (session.LookScheduled) return;
        session.LookScheduled = true;
        After(delay, () =>
        {
            session.LookScheduled = false;
            var quiet = _time.GetUtcNow() - session.LastOutputAt;
            if (quiet < _quietBeforeAsking) { ScheduleLook(session, _quietBeforeAsking - quiet); return; }
            LookForQuestion(session);
        });
    }

    /// <summary>
    /// Answers a program asking whether the terminal speaks OSC 7501 (before anything goes out: its answer must arrive
    /// ahead of the terminal's reply to the device attributes query that follows), and follows what it then reports.
    /// A program killed mid-task never clears its records: once another program is in front and the reporter is gone,
    /// nothing it said holds. One that is only in the background keeps its status for when it comes back.
    /// </summary>
    private void ReadStatus(byte[] data, Session session, DateTimeOffset now)
    {
        var summaries = new List<ProgramStatus.Summary?>();
        var outcome = session.ProgramStatus.Scan(data, summaries);
        if (outcome.HasFlag(ProgramStatus.Outcome.Queried)) session.Pty.Write(ProgramStatus.SupportReply);
        var changed = outcome.HasFlag(ProgramStatus.Outcome.Changed);
        if (!session.ProgramStatus.IsEmpty)
        {
            var job = session.Pty.ForegroundJob;
            if (session.StatusOwner is null)
            {
                if (session.Pty.ShellIsInFront(job)) { if (session.ProgramStatus.ForgetAll()) summaries.Add(null); }
                else session.StatusOwner = job;
            }
            else if (session.StatusOwner is { } owner && job is { } front && front != owner && !session.Pty.JobExists(owner))
            {
                if (!changed || session.Pty.ShellIsInFront(job)) { if (session.ProgramStatus.ForgetAll()) summaries.Add(null); }
                else session.StatusOwner = job; // another program in front reported: what is said now is its
            }
        }
        if (session.ProgramStatus.IsEmpty) session.StatusOwner = null;
        // Each change in turn: a moment's state (done, then the program gone) still counts.
        foreach (var summary in summaries) UpdateStatus(session, summary, now);
    }

    private void UpdateStatus(Session session, ProgramStatus.Summary? summary, DateTimeOffset now)
    {
        var previous = session.Status;
        ShellStatus? next = null;
        if (summary is { } s)
        {
            var sameState = previous?.State == s.State;
            var finished = s.State is ShellStatus.Done or ShellStatus.Failed;
            next = new ShellStatus
            {
                State = s.State,
                Kind = s.Kind,
                Message = s.Message is null ? null : OneLine(s.Message, ShellStatus.MaxMessage),
                Agents = s.Agents,
                Since = sameState ? previous!.Since : TranscriptStore.Seconds(now),
                // Done while someone is looking at it: they saw it.
                Seen = finished && ((sameState && previous?.Seen == true) || IsLooked(session)),
            };
        }
        if (next == previous) return;
        session.Status = next;
        // What it is doing while it works changes with every step and nothing shows it: that alone goes out with the next change that shows.
        var shown = next?.State != previous?.State || next?.Kind != previous?.Kind || next?.Seen != previous?.Seen
            || next?.Agents != previous?.Agents || (next?.IsBlocked == true && next.Message != previous?.Message);
        if (!shown) return;
        NotifyChange();
        NotifyStatus(session);
    }

    private static bool IsLooked(Session session) => session.Attachment?.IsLooking == true;

    private void NotifyStatus(Session session)
    {
        if (StatusChanged is not { } handler) return;
        var info = session.Info;
        var looking = IsLooked(session);
        _callouts.Post(() => handler(info, looking));
    }

    /// <summary>Someone has the session in front of them: a result waiting there is seen.</summary>
    private void MarkResultSeen(Session session)
    {
        if (session.Status is not { IsUnseenResult: true } status) return;
        session.Status = status with { Seen = true };
        NotifyChange();
        NotifyStatus(session);
    }

    private static string OneLine(string text, int limit)
    {
        var line = string.Join(' ', text.Split(['\r', '\n', '\u0085', (char)0x2028, (char)0x2029], StringSplitOptions.RemoveEmptyEntries));
        var info = new StringInfo(line);
        return info.LengthInTextElements > limit ? info.SubstringByTextElements(0, limit - 1) + "…" : line;
    }

    private void LookForQuestion(Session session)
    {
        // A program that reports its status says when it is asking.
        if (!session.Running || session.CheckedSinceOutput || session.Status is not null) return;
        if (!_table.TryGetValue(session.Id, out var current) || current != session) return;
        session.CheckedSinceOutput = true;
        var question = ShellQuestion.Find(session.Tail);
        if (question == session.Waiting) return;
        session.Waiting = question;
        NotifyChange();
    }

    private void Ended(Session session, int status)
    {
        if (!session.Running) return;
        session.Running = false;
        session.ExitStatus = status;
        session.Writer.Finish(status, _time.GetUtcNow());
        if (session.Status is not null) NotifyStatus(session);
        if (session.Attachment is { } client)
        {
            var id = session.Id;
            _callouts.Post(() => client.ShellEnded(id, status));
        }
        session.Attachment = null;
        session.Active = null;
        // Off the lock: closing a pseudo-terminal can wait on its reader, which may be waiting on the lock.
        var pty = session.Pty;
        ThreadPool.UnsafeQueueUserWorkItem(_ => pty.Dispose(), null);
        _log?.Invoke($"shell: session ended ({status})");
        NotifyChange();
        After(_endedRetention, () =>
        {
            if (!_table.TryGetValue(session.Id, out var current) || current != session) return;
            Remove(session.Id);
            NotifyChange();
        });
    }

    /// <summary>
    /// The first typed line the shell echoed back becomes the title, so a line typed at a no-echo prompt (a password)
    /// never does. Only printable input counts; escape sequences are skipped whole, and ctrl-C or ctrl-U start over.
    /// </summary>
    private void LearnTitle(byte[] data, Session session)
    {
        foreach (var b in data)
        {
            switch (session.InputEscape)
            {
                case InputEscape.Escape:
                    session.InputEscape = b == 0x5B ? InputEscape.Csi : b == 0x4F ? InputEscape.Ss3 : InputEscape.None;
                    continue;
                case InputEscape.Csi:
                    if (b is >= 0x40 and <= 0x7E) session.InputEscape = InputEscape.None;
                    continue;
                case InputEscape.Ss3:
                    session.InputEscape = InputEscape.None;
                    continue;
            }
            switch (b)
            {
                case 0x1B:
                    session.InputEscape = InputEscape.Escape;
                    break;
                case 0x0D:
                    var line = Encoding.UTF8.GetString([.. session.Typed]).Trim(' ', '\t');
                    var from = session.LineStart ?? session.OutputCount;
                    session.Typed = [];
                    session.LineStart = null;
                    if (line.Length == 0) continue;
                    var info = new StringInfo(line);
                    var title = info.LengthInTextElements > TitleLimit ? info.SubstringByTextElements(0, TitleLimit) : line;
                    session.PendingTitle = (title, from, session.OutputCount + EchoWindow);
                    AdoptEchoedTitle(session);
                    if (session.TitleKnown) return;
                    break;
                case 0x03 or 0x15:
                    session.Typed = [];
                    session.LineStart = null;
                    break;
                case 0x7F or 0x08:
                    if (session.Typed.Count > 0) session.Typed.RemoveAt(session.Typed.Count - 1);
                    break;
                case >= 0x20:
                    if (session.Typed.Count >= TypedLimit) continue;
                    if (session.Typed.Count == 0 && session.LineStart is null) session.LineStart = session.OutputCount;
                    session.Typed.Add(b);
                    break;
            }
        }
    }

    /// <summary>Makes the pending line the title if the output since it was typed shows it; drops it once its echo window has passed.</summary>
    private void AdoptEchoedTitle(Session session)
    {
        if (session.PendingTitle is not { } pending || session.TitleKnown) return;
        var since = (int)Math.Min(session.OutputCount - pending.From, RemoteShell.ScrollbackBytes);
        var contents = session.Scrollback.Contents;
        if (EchoShows(pending.Text, contents[Math.Max(0, contents.Length - since)..]))
        {
            session.PendingTitle = null;
            session.Title = pending.Text;
            session.TitleKnown = true;
            session.Writer.SetTitle(session.Title);
            NotifyChange();
        }
        else if (session.OutputCount >= pending.Until)
        {
            session.PendingTitle = null;
        }
    }

    /// <summary>Whether <paramref name="output"/> shows <paramref name="line"/> on one line.</summary>
    internal static bool EchoShows(string line, ReadOnlySpan<byte> output) =>
        VisibleText(output).AsSpan().IndexOf(Encoding.UTF8.GetBytes(line)) >= 0;

    /// <summary>
    /// Output without escape sequences or control characters: what a line editor's echo looks like once its colours and
    /// cursor moves are gone. CR and LF become a line break (LF), so text either side stays apart.
    /// </summary>
    internal static byte[] VisibleText(ReadOnlySpan<byte> data)
    {
        var o = new List<byte>(data.Length);
        var state = 0; // 0 text, 1 after ESC, 2 CSI, 3 OSC/DCS string, 4 ESC inside a string
        foreach (var b in data)
        {
            switch (state)
            {
                case 1: state = b == 0x5B ? 2 : b is 0x5D or 0x50 ? 3 : 0; break;
                case 2: if (b is >= 0x40 and <= 0x7E) state = 0; break;
                case 3: if (b == 0x07) state = 0; else if (b == 0x1B) state = 4; break;
                case 4: state = b == 0x5C ? 0 : 3; break;
                default:
                    if (b == 0x1B) state = 1;
                    else if (b is 0x0D or 0x0A) o.Add(0x0A);
                    else if (b >= 0x20 && b != 0x7F) o.Add(b);
                    break;
            }
        }
        return [.. o];
    }

    private void Remove(string id)
    {
        _table.Remove(id);
        _order.Remove(id);
    }

    private void NotifyChange()
    {
        if (Changed is { } handler) _callouts.Post(handler);
    }

    /// <summary>Runs <paramref name="action"/> under the lock after <paramref name="delay"/>.</summary>
    private void After(TimeSpan delay, Action action)
    {
        ITimer? timer = null;
        timer = _time.CreateTimer(_ =>
        {
            lock (_lock)
            {
                if (timer is null || !_timers.Remove(timer)) return;
                timer.Dispose();
                action();
            }
        }, null, delay, Timeout.InfiniteTimeSpan);
        _timers.Add(timer);
    }

    private static int Dimension(int value) => Math.Clamp(value, 1, ushort.MaxValue);
}
