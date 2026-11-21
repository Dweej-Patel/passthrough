using System.Diagnostics;
using System.Text;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Windows.Shell;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>Real sessions in the bundled pseudoconsole.</summary>
public sealed class ConPtyTests : IDisposable
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);
    private static readonly string Cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
    private readonly List<ConPty> _ptys = [];

    public void Dispose() => _ptys.ForEach(p => p.Dispose());

    private sealed class Recorder
    {
        private readonly List<byte> _output = [];
        public readonly TaskCompletionSource<int> Exited = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool OutputAfterExit;
        public string Text { get { lock (_output) return Encoding.UTF8.GetString([.. _output]); } }

        public void Attach(IPty pty)
        {
            pty.OnOutput = data => { lock (_output) _output.AddRange(data); if (Exited.Task.IsCompleted) OutputAfterExit = true; };
            pty.OnExit = code => Exited.TrySetResult(code);
        }

        public void WaitFor(string text)
        {
            var deadline = DateTime.UtcNow + Patience;
            while (!Text.Contains(text, StringComparison.Ordinal))
            {
                if (DateTime.UtcNow > deadline) throw new TimeoutException($"never saw {text}; got: {Text}");
                Thread.Sleep(20);
            }
        }
    }

    private (ConPty Pty, Recorder Recorder) Start(string[] arguments, Dictionary<string, string>? environment = null)
    {
        var start = new PtyStart(Cmd, arguments, UserEnvironment.Home, environment ?? new Dictionary<string, string>(UserEnvironment.Create()), 80, 24);
        var pty = new ConPty(start);
        _ptys.Add(pty);
        var recorder = new Recorder();
        recorder.Attach(pty);
        pty.Start();
        return (pty, recorder);
    }

    [Fact]
    public void TheBundledPseudoconsoleIsBesideTheApp()
    {
        Assert.True(ConPty.IsAvailable);
    }

    [Fact]
    public async Task OutputComesThenTheExitCode()
    {
        var (_, recorder) = Start(["/d", "/c", "echo hello from conpty & exit 7"]);
        Assert.Equal(7, await recorder.Exited.Task.WaitAsync(Patience));
        Assert.Contains("hello from conpty", recorder.Text);
        Assert.False(recorder.OutputAfterExit, "the exit comes after the last output");
        // The pseudoconsole's own opening never reaches a phone.
        Assert.DoesNotContain("\u001b[?9001h", recorder.Text);
    }

    [Fact]
    public async Task TypingReachesTheShellWithOnlyTheEnvironmentGiven()
    {
        Environment.SetEnvironmentVariable("PASSTHROUGH_ONLY_IN_THE_TEST_PROCESS", "leaked");
        var environment = new Dictionary<string, string>(UserEnvironment.Create(), StringComparer.OrdinalIgnoreCase) { ["PASSTHROUGH_GIVEN"] = "given-value" };
        var (pty, recorder) = Start(["/d", "/k"], environment);
        pty.Write("echo [%PASSTHROUGH_GIVEN%] [%PASSTHROUGH_ONLY_IN_THE_TEST_PROCESS%] [%TERM_PROGRAM%]\r"u8);
        recorder.WaitFor("[given-value] [%PASSTHROUGH_ONLY_IN_THE_TEST_PROCESS%] [Passthrough]");
        pty.Resize(100, 30);
        pty.Write("exit 0\r"u8);
        Assert.Equal(0, await recorder.Exited.Task.WaitAsync(Patience));
    }

    [Fact]
    public async Task EndingTheSessionEndsWhatTheShellStarted_AndWhatIsInFrontIsKnown()
    {
        var (pty, recorder) = Start(["/d", "/k"]);
        recorder.WaitFor(">");
        Assert.True(pty.ShellIsInFront(pty.ForegroundJob));
        pty.Write("ping -n 120 127.0.0.1\r"u8);
        recorder.WaitFor("127.0.0.1");
        long? front = null;
        var deadline = DateTime.UtcNow + Patience;
        while (DateTime.UtcNow < deadline && (front = pty.ForegroundJob) == pty.ProcessId) Thread.Sleep(100);
        Assert.NotNull(front);
        Assert.False(pty.ShellIsInFront(front), "ping is in front");
        Assert.True(pty.JobExists(front!.Value));
        var ping = Process.GetProcessById((int)front.Value);
        Assert.Equal("PING", ping.ProcessName.ToUpperInvariant());

        pty.Terminate();
        Assert.Equal(ConPty.TerminatedExitCode, await recorder.Exited.Task.WaitAsync(Patience));
        Assert.True(ping.WaitForExit(5000), "ping ended with the session");
        Assert.False(pty.JobExists(front.Value));
    }

    [Fact]
    public void AProgramGivenWithoutItsFullPathIsRefused()
    {
        Assert.Throws<ArgumentException>(() => new ConPty(new PtyStart("cmd.exe", [], UserEnvironment.Home, new Dictionary<string, string>(), 80, 24)));
    }

    [Fact]
    public void TheCatalogFindsThisPcsShells()
    {
        var catalog = ShellCatalog.Discover(new ShellProbe());
        Assert.Contains(catalog.Shells, s => s.Id == "cmd");
        Assert.Contains(catalog.Shells, s => s.Id == "powershell");
        Assert.NotNull(catalog.Default);
        Assert.All(catalog.Shells, s => Assert.True(Path.IsPathFullyQualified(catalog.Resolve(s.Id).Executable)));
    }

    [Fact]
    public void TestsDoNotRunElevated()
    {
        // The app refuses to host shells elevated; these tests are the same process kind it is.
        Assert.False(UserEnvironment.IsElevated(), "run the tests as yourself, not as administrator");
    }
}

/// <summary>The session manager over real pseudoconsoles: what a phone sees.</summary>
public sealed class SessionManagerOnConPtyTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"SessionManagerOnConPty-{Guid.NewGuid():N}");
    private readonly ShellSessionManager _manager;

    public SessionManagerOnConPtyTests()
    {
        var catalog = ShellCatalog.Discover(new ShellProbe());
        _manager = new ShellSessionManager(new TranscriptStore(_directory), catalog.Resolve, start => new ConPty(start),
            UserEnvironment.Create, UserEnvironment.Home, quietBeforeAsking: TimeSpan.FromMilliseconds(300));
    }

    public void Dispose()
    {
        _manager.CloseAll();
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private sealed class Phone : IShellAttachment
    {
        private readonly List<byte> _output = [];
        public string Text { get { lock (_output) return Encoding.UTF8.GetString([.. _output]); } }
        public int? Ended;
        public void ShellOutput(byte[] data, string session) { lock (_output) _output.AddRange(data); }
        public void ShellEnded(string session, int exitStatus) => Ended = exitStatus;
        public void ShellDetached(string session, ulong generation) { }
    }

    private static void Until(Func<bool> condition, string what)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException(what);
            Thread.Sleep(20);
        }
    }

    private ShellSessionInfo Info(string id) => _manager.Sessions.Single(s => s.Id == id);

    [Fact]
    public void APhoneUsesAShellAndItsTitleAndTranscriptFollow()
    {
        var id = _manager.Open("iPhone", 80, 24, "phone", "cmd");
        var phone = new Phone();
        _manager.Attach(id, phone, 80, 24);
        Until(() => phone.Text.Contains('>'), "a prompt");
        _manager.Input(id, "echo %PASSTHROUGH_SESSION%\r"u8, phone);
        Until(() => phone.Text.Contains(id), "the session's id from its environment");
        Until(() => Info(id).Title == "echo %PASSTHROUGH_SESSION%", "the title");
        _manager.Input(id, "exit 4\r"u8, phone);
        Until(() => phone.Ended == 4, "the end");
        Assert.False(Info(id).Running);
        Assert.Contains(id, Encoding.UTF8.GetString(new TranscriptStore(_directory).Output(id)));
    }

    [Fact]
    public void AQuestionAtTheBottomIsWaiting()
    {
        var id = _manager.Open("iPhone", 80, 24, "phone", "cmd");
        _manager.Attach(id, new Phone(), 80, 24);
        _manager.Input(id, "set /p ANSWER=Overwrite it? [y/N] \r"u8);
        Until(() => Info(id).Waiting == "Overwrite it? [y/N]", "waiting on the question");
        _manager.Input(id, "y\r"u8);
        Until(() => Info(id).Waiting is null, "answered");
    }

    [Fact]
    public void AProgramsStatusReachesThePhoneAndGoesWithIt()
    {
        var catalog = ShellCatalog.Discover(new ShellProbe());
        var powershell = catalog.Resolve("powershell").Executable;
        var id = _manager.Open("iPhone", 80, 24, "phone", "cmd");
        _manager.Attach(id, new Phone(), 80, 24);
        // A program the shell started reports, as Claude Code does.
        var report = "[Console]::Out.Write([char]27 + ']7501;state=working:msg=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Reading files')) + [char]7); Start-Sleep 600";
        _manager.Input(id, Encoding.UTF8.GetBytes($"\"{powershell}\" -NoProfile -Command \"{report}\"\r"));
        Until(() => Info(id).Status?.State == ShellStatus.Working, "working");
        Assert.Equal("Reading files", Info(id).Status?.Message);
        // Stopped with ^C: the program is gone, the prompt is back, and what it said goes with it.
        _manager.Input(id, "\u0003"u8);
        _manager.Input(id, "echo back\r"u8);
        Until(() => Info(id).Status is null, "forgotten once the program is gone");
    }
}
