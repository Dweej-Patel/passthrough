using System.Collections.Concurrent;
using System.Text;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Sessions;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>A pseudo-terminal that prints what the test says and records what it is sent.</summary>
internal sealed class FakePty(PtyStart start) : IPty
{
    public const long ShellJob = 1;
    private readonly object _lock = new();
    private readonly List<byte> _written = [];
    public PtyStart StartInfo { get; } = start;
    public Action<byte[]>? OnOutput { get; set; }
    public Action<int>? OnExit { get; set; }
    public bool Started { get; private set; }
    public bool Disposed { get; private set; }
    public List<(int Cols, int Rows)> Sizes { get; } = [];
    public long? ForegroundJob { get; set; } = ShellJob;
    public HashSet<long> LiveJobs { get; } = [ShellJob];
    private bool _exited;

    public string Written { get { lock (_lock) return Encoding.UTF8.GetString([.. _written]); } }
    public void Start() => Started = true;
    public void Write(ReadOnlySpan<byte> data) { lock (_lock) _written.AddRange(data.ToArray()); }
    public void Resize(int cols, int rows) { lock (_lock) Sizes.Add((cols, rows)); }
    public void Terminate() => Exit(-1073741510); // STATUS_CONTROL_C_EXIT, as a console program ended this way reports
    public bool JobExists(long job) => LiveJobs.Contains(job);
    public bool ShellIsInFront(long? job) => job == ShellJob;
    public void Dispose() => Disposed = true;

    public void Print(string text) => OnOutput?.Invoke(Encoding.UTF8.GetBytes(text));
    public void Print(byte[] data) => OnOutput?.Invoke(data);

    public void Exit(int code)
    {
        lock (_lock) { if (_exited) return; _exited = true; }
        OnExit?.Invoke(code);
    }
}

internal sealed class RecordingClient(bool looking = true) : IShellAttachment
{
    private readonly ConcurrentQueue<string> _events = new();
    private readonly List<byte> _output = [];
    public bool IsLooking => looking;
    public List<string> Events => [.. _events];
    public string Text { get { lock (_output) return Encoding.UTF8.GetString([.. _output]); } }
    public void ShellOutput(byte[] data, string session) { lock (_output) _output.AddRange(data); _events.Enqueue($"output {data.Length}"); }
    public void ShellEnded(string session, int exitStatus) => _events.Enqueue($"ended {exitStatus}");
    public void ShellDetached(string session, ulong generation) => _events.Enqueue($"detached {generation}");
    public void ShellReplaying(string session) => _events.Enqueue("replaying");
    public void ShellReplayed(string session) => _events.Enqueue("replayed");
}

/// <summary>Ports of ShellSessionManagerTests.swift and the phone cases of ProgramStatusTests/SharedSessionTests/TerminalModesTests, over a fake pseudo-terminal.</summary>
public sealed class ShellSessionManagerTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"ShellSessionManagerTests-{Guid.NewGuid():N}");
    private readonly FakeTimeProvider _time = new(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
    private readonly List<FakePty> _ptys = [];
    private readonly ShellSessionManager _manager;
    private int _changes;

    private static readonly ShellCommand Pwsh = new("pwsh", @"C:\Program Files\PowerShell\7\pwsh.exe", ["-NoLogo"]);
    private static readonly ShellCommand Cmd = new("cmd", @"C:\Windows\System32\cmd.exe", []);

    public ShellSessionManagerTests()
    {
        _manager = new ShellSessionManager(
            new TranscriptStore(_directory),
            id => id switch
            {
                null or "pwsh" => Pwsh,
                "cmd" => Cmd,
                _ => throw new ShellException(ShellError.BadRequest),
            },
            start => { var pty = new FakePty(start); lock (_ptys) _ptys.Add(pty); return pty; },
            () => new Dictionary<string, string> { ["PATH"] = @"C:\Windows\System32", ["TERM"] = "xterm-256color" },
            @"C:\Users\dev",
            time: _time);
        _manager.Changed += () => Interlocked.Increment(ref _changes);
    }

    public void Dispose()
    {
        _manager.CloseAll();
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private FakePty Pty(int index = -1) { lock (_ptys) return index < 0 ? _ptys[^1] : _ptys[index]; }
    private ShellSessionInfo Info(string id) => _manager.Sessions.Single(s => s.Id == id);
    private string Open(string? phoneId = null, string? shell = null) => _manager.Open("iPhone", 80, 24, phoneId, shell);
    private void Type(string id, string text, IShellAttachment? client = null) => _manager.Input(id, Encoding.UTF8.GetBytes(text), client);
    private void Settle() => _manager.FlushCallouts();
    private static string B64(string text) => Convert.ToBase64String(Encoding.UTF8.GetBytes(text));

    // MARK: Opening

    [Fact]
    public void OpenStartsTheCatalogsShellInTheHomeFolderSayingItIsASession()
    {
        var id = Open();
        var pty = Pty();
        Assert.True(pty.Started);
        Assert.Equal(Pwsh.Executable, pty.StartInfo.Executable);
        Assert.Equal(["-NoLogo"], pty.StartInfo.Arguments);
        Assert.Equal(@"C:\Users\dev", pty.StartInfo.Directory);
        Assert.Equal(id, pty.StartInfo.Environment[RemoteShell.SessionVariable]);
        Assert.Equal("xterm-256color", pty.StartInfo.Environment["TERM"]);
        Assert.Equal((80, 24), (pty.StartInfo.Cols, pty.StartInfo.Rows));
        var info = Info(id);
        Assert.True(info.Running);
        Assert.Equal("~", info.Title);
        Assert.Equal("pwsh", info.Shell);

        var other = Open(shell: "cmd");
        Assert.Equal(Cmd.Executable, Pty().StartInfo.Executable);
        Assert.Equal("cmd", Info(other).Shell);
    }

    [Fact]
    public void AShellNotInTheCatalogIsRefusedAndHoldsNoSlot()
    {
        var error = Assert.Throws<ShellException>(() => Open(shell: @"C:\evil.exe"));
        Assert.Equal(ShellError.BadRequest, error.Error);
        for (var i = 0; i < RemoteShell.MaxSessions; i++) Open();
        Assert.Equal(RemoteShell.MaxSessions, _manager.Sessions.Count);
    }

    [Fact]
    public void TheCapIsEnforced_AndEndedSessionsDoNotCount()
    {
        for (var i = 0; i < RemoteShell.MaxSessions; i++) Open();
        Assert.Equal(ShellError.TooManySessions, Assert.Throws<ShellException>(() => Open()).Error);
        Pty(0).Exit(0);
        Open();
        Assert.Equal(RemoteShell.MaxSessions, _manager.Sessions.Count); // the ended one made room
    }

    [Fact]
    public void RevokingAPhoneEndsTheSessionsItOpenedOnly()
    {
        var mine = Open("phone-a");
        var theirs = Open("phone-b");
        _manager.CloseSessions("phone-a");
        Assert.False(Info(mine).Running);
        Assert.True(Info(theirs).Running);
    }

    // MARK: Attaching

    [Fact]
    public void OutputWhileDetachedIsReplayedInChunksBetweenReplayingAndReplayed()
    {
        var id = Open();
        Pty().Print(new string('x', RemoteShell.OutputChunk * 2 + 10));
        var client = new RecordingClient();
        _manager.Attach(id, client, 80, 24);
        Pty().Print("live");
        Settle();
        Assert.Equal(["replaying", $"output {RemoteShell.OutputChunk}", $"output {RemoteShell.OutputChunk}", "output 10", "replayed", "output 4"], client.Events);
        Assert.EndsWith("xlive", client.Text);
    }

    [Fact]
    public void AttachingToAnUnknownSessionThrows()
    {
        Assert.Equal(ShellError.NoSuchSession, Assert.Throws<ShellException>(() => _manager.Attach("nope", new RecordingClient(), 80, 24)).Error);
    }

    [Fact]
    public void ASecondAttachTakesOver_AndDetachStopsDelivery()
    {
        var id = Open();
        var first = new RecordingClient();
        var second = new RecordingClient();
        var g1 = _manager.Attach(id, first, 80, 24);
        var g2 = _manager.Attach(id, second, 80, 24);
        Assert.True(g2 > g1);
        Assert.Equal(g2, _manager.AttachmentGeneration(id));
        Pty().Print("after");
        Settle();
        Assert.Contains($"detached {g1}", first.Events);
        Assert.DoesNotContain("after", first.Text);
        Assert.Equal("after", second.Text);
        _manager.Detach(second);
        Pty().Print("gone");
        Settle();
        Assert.Equal("after", second.Text);
        Assert.Null(_manager.AttachmentGeneration(id));
    }

    [Fact]
    public void TheTerminalTakesTheAttachingClientsSize_AndItsResizes()
    {
        var id = Open();
        var phone = new RecordingClient();
        _manager.Attach(id, phone, 48, 20);
        _manager.Resize(id, 50, 21, phone);
        _manager.Resize(id, 50, 21, phone); // unchanged
        _manager.Resize(id, 0, 99999); // clamped
        Assert.Equal([(48, 20), (50, 21), (1, 65535)], Pty().Sizes);
        // A phone the session doesn't follow any more doesn't resize it.
        var other = new RecordingClient();
        _manager.Attach(id, other, 30, 10);
        _manager.Resize(id, 99, 99, phone);
        Assert.Equal((30, 10), Pty().Sizes[^1]);
    }

    [Fact]
    public void AnExitReachesTheAttachment_ALaterAttachSeesTheEnd_AndItIsPrunedAfterRetention()
    {
        var id = Open();
        var client = new RecordingClient();
        _manager.Attach(id, client, 80, 24);
        Pty().Print("bye");
        Pty().Exit(3);
        Settle();
        Assert.Equal("ended 3", client.Events[^1]);
        var info = Info(id);
        Assert.False(info.Running);
        Assert.Equal(3, info.ExitStatus);
        Assert.Null(info.Waiting);

        var late = new RecordingClient();
        _manager.Attach(id, late, 80, 24);
        Settle();
        Assert.Equal(["replaying", "output 3", "replayed", "ended 3"], late.Events);

        _time.Advance(TimeSpan.FromMinutes(9));
        Assert.Single(_manager.Sessions);
        _time.Advance(TimeSpan.FromMinutes(1.1));
        Assert.Empty(_manager.Sessions);
    }

    [Fact]
    public void CloseAllFinishesTranscripts()
    {
        var id = Open();
        Pty().Print("hello");
        _manager.CloseAll();
        Assert.False(Info(id).Running);
        var store = new TranscriptStore(_directory);
        Assert.NotNull(store.Entries().Single(e => e.Id == id).EndedAt);
        Assert.Equal("hello", Encoding.UTF8.GetString(store.Output(id)));
        Assert.True(SpinWait.SpinUntil(() => Pty().Disposed, 5000), "the pseudo-terminal is closed");
    }

    // MARK: Titles

    [Fact]
    public void TheTitleIsTheFirstEchoedCommand()
    {
        var id = Open();
        Type(id, "ls -la\r");
        Assert.Equal("~", Info(id).Title);
        Pty().Print("\u001b[32mls\u001b[0m -la\r\nfile\r\n");
        Assert.Equal("ls -la", Info(id).Title);
        Type(id, "git status\r");
        Pty().Print("git status\r\n");
        Assert.Equal("ls -la", Info(id).Title); // the first one stays
        var store = new TranscriptStore(_directory);
        Assert.Equal("ls -la", store.Entries().Single().Title);
    }

    [Fact]
    public void AnUnechoedLineIsNeverTheTitle()
    {
        var id = Open();
        Pty().Print("Password: ");
        Type(id, "hunter2\r");
        Pty().Print("\r\n" + new string('.', 2100) + "\r\n$ ");
        Type(id, "whoami\r");
        Pty().Print("whoami\r\ndev\r\n");
        Assert.Equal("whoami", Info(id).Title);
    }

    [Fact]
    public void EscapesAndClearedLinesStayOutOfTheTitle()
    {
        var id = Open();
        Type(id, "\u001b[A\u001bOBoops\u0015ec\u007fcho hi\r");
        Pty().Print("echo hi\r\n");
        Assert.Equal("echo hi", Info(id).Title);

        var other = Open();
        Type(other, new string('a', 100) + "\r");
        Pty().Print(new string('a', 100) + "\r\n");
        Assert.Equal(new string('a', 60), Info(other).Title);
    }

    [Fact]
    public void VisibleTextDropsEscapes_AndAnEchoCannotSpanALineBreak()
    {
        Assert.Equal("ls -la", Encoding.UTF8.GetString(ShellSessionManager.VisibleText("\u001b[1mls\u001b[0m\u001b]0;t\u0007 -la"u8)));
        Assert.False(ShellSessionManager.EchoShows("echo hi", "ec\r\nho hi"u8));
        Assert.True(ShellSessionManager.EchoShows("echo hi", "\u001b[2Kecho hi"u8));
    }

    // MARK: Waiting on a question

    [Fact]
    public void AQuestionIsWaitingOnceQuiet_UntilAnswered_AndStaysAnswered()
    {
        var id = Open();
        Pty().Print("Removing 3 files\r\nProceed? [y/N] ");
        _time.Advance(TimeSpan.FromSeconds(1));
        Assert.Null(Info(id).Waiting);
        _time.Advance(TimeSpan.FromSeconds(0.6));
        Assert.Equal("Proceed? [y/N]", Info(id).Waiting);
        Type(id, "y\r");
        Assert.Null(Info(id).Waiting);
        Pty().Print("y\r\nPS C:\\> ");
        _time.Advance(TimeSpan.FromSeconds(2));
        Assert.Null(Info(id).Waiting); // the answered question above the prompt isn't found again
    }

    [Fact]
    public void StreamingOutputPushesTheLookBack()
    {
        var id = Open();
        Pty().Print("Continue? [y/N] ");
        _time.Advance(TimeSpan.FromSeconds(1));
        Pty().Print("\u001b[0m");
        _time.Advance(TimeSpan.FromSeconds(1));
        Assert.Null(Info(id).Waiting);
        _time.Advance(TimeSpan.FromSeconds(0.6));
        Assert.Equal("Continue? [y/N]", Info(id).Waiting);
    }

    [Fact]
    public void APromptIsNotAQuestion()
    {
        var id = Open();
        Pty().Print("PS C:\\Users\\dev> ");
        _time.Advance(TimeSpan.FromSeconds(2));
        Assert.Null(Info(id).Waiting);
    }

    // MARK: Program status

    [Fact]
    public void TheHostAnswersTheStatusQueryAndFollowsReports()
    {
        var id = Open();
        Pty().Print("\u001b]7501;?\u0007\u001b[c");
        Assert.Equal(Encoding.ASCII.GetString(ProgramStatus.SupportReply), Pty().Written);
        Pty().ForegroundJob = 7;
        Pty().LiveJobs.Add(7);
        Pty().Print($"\u001b]7501;state=working:msg={B64("Reading files")}\u0007");
        Assert.Equal(ShellStatus.Working, Info(id).Status?.State);
        Assert.Equal("Reading files", Info(id).Status?.Message);
        Assert.Null(Info(id).Waiting);
        Pty().Print($"\u001b]7501;state=blocked:kind=question:msg={B64("Pick a colour?")}\u0007");
        Assert.Equal("question", Info(id).Status?.Kind);
        Assert.Equal("Pick a colour?", Info(id).Waiting);
        // Killed without clearing: once the shell's prompt is back and the program is gone, nothing it said stands.
        Pty().LiveJobs.Remove(7);
        Pty().ForegroundJob = FakePty.ShellJob;
        Pty().Print("^C\r\nPS C:\\> ");
        Assert.Null(Info(id).Status);
        Assert.Null(Info(id).Waiting);
    }

    [Fact]
    public void ABackgroundedProgramKeepsItsStatus()
    {
        var id = Open();
        Pty().ForegroundJob = 7;
        Pty().LiveJobs.Add(7);
        Pty().Print($"\u001b]7501;state=blocked:kind=permission:msg={B64("approve Bash: ls")}\u0007");
        Pty().ForegroundJob = FakePty.ShellJob; // still alive, just not in front
        Pty().Print("[1]+  Stopped\r\n$ ");
        Assert.Equal(ShellStatus.Blocked, Info(id).Status?.State);
        Assert.Equal("approve Bash: ls", Info(id).Waiting);
    }

    [Fact]
    public void AReportFromTheShellItselfIsForgotten()
    {
        var id = Open();
        Pty().Print("\u001b]7501;state=working\u0007");
        Assert.Null(Info(id).Status);
    }

    [Fact]
    public void DoneIsSeenOnlyWhileSomeoneLooks()
    {
        var id = Open();
        var away = new RecordingClient(looking: false);
        _manager.Attach(id, away, 80, 24);
        Pty().ForegroundJob = 7;
        Pty().LiveJobs.Add(7);
        Pty().Print("\u001b]7501;state=working\u0007\u001b]7501;state=done\u0007");
        Assert.False(Info(id).Status!.Seen);
        Assert.True(Info(id).Status!.IsUnseenResult);
        _manager.LookedAt(away);
        Assert.True(Info(id).Status!.Seen);

        var other = Open();
        Pty().ForegroundJob = 8;
        Pty().LiveJobs.Add(8);
        Pty().Print("\u001b]7501;state=done\u0007");
        Assert.False(Info(other).Status!.Seen);
        _manager.Attach(other, new RecordingClient(), 80, 24);
        Assert.True(Info(other).Status!.Seen);
    }

    [Fact]
    public void StatusChangesAreReportedInOrder()
    {
        var seen = new ConcurrentQueue<string>();
        _manager.StatusChanged += (info, looking) => seen.Enqueue($"{info.Status?.State ?? "none"}{(info.Running ? "" : " ended")}");
        var id = Open();
        Pty().ForegroundJob = 7;
        Pty().LiveJobs.Add(7);
        Pty().Print("\u001b]7501;state=working\u0007\u001b]7501;state=working:msg=" + B64("step") + "\u0007\u001b]7501;state=done\u0007");
        Pty().Exit(0);
        Settle();
        Assert.Equal(["working", "done", "none ended"], seen);
        Assert.False(Info(id).Running);
    }

    // MARK: Full-screen programs

    [Fact]
    public void AttachingToAFullScreenProgramReplayedFromPartwayRedrawsIt()
    {
        var id = Open();
        Pty().Print("\u001b[?1049h");
        for (var i = 0; i < 80; i++) Pty().Print($"\u001b[H frame {i} " + new string('#', 16_384) + "\n");
        var phone = new RecordingClient();
        _manager.Attach(id, phone, 80, 24); // the size it already has
        Assert.Equal([(80, 23)], Pty().Sizes);
        _time.Advance(ShellSessionManager.RedrawPause);
        Assert.Equal([(80, 23), (80, 24)], Pty().Sizes);
        Settle();
        Assert.StartsWith("\u001b[?1049h", phone.Text);
    }

    // MARK: Terminal reports

    [Fact]
    public void ReportsFromATerminalTheSessionDoesNotFollowAreDropped()
    {
        var id = Open();
        var first = new RecordingClient();
        var second = new RecordingClient();
        _manager.Attach(id, first, 80, 24);
        _manager.Attach(id, second, 80, 24);
        Type(id, "\u001b[24;1R", first);
        Type(id, "\u001b[12;1R", second);
        Type(id, "\u001b]7501;?:states=idle\u001b\\ls", second);
        Assert.Equal("\u001b[12;1Rls", Pty().Written);
    }
}
