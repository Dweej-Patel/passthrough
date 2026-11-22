using System.Net;
using System.Net.Sockets;
using System.Text;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>Ports of ShellListenerTests.swift's gate and connection cases, over loopback TCP and fake pseudoterminals.</summary>
public class ShellGateTests : IAsyncDisposable
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(10);
    private static readonly byte[] KeyA = Enumerable.Repeat((byte)7, 32).ToArray();
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"ShellGateTests-{Guid.NewGuid():N}");
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly List<FakePty> _ptys = [];
    private readonly ShellAccessStore _access = new(new MemorySecretStore());
    private readonly ShellSessionManager _manager;
    private readonly ShellGate _gate;
    private readonly List<string> _events = [];
    private readonly CancellationTokenSource _stop = new();
    private Func<string, ShellError?>? _lock;
    /// <summary>This PC's Remote Desktop as the relay sees it: not available until a test says otherwise.</summary>
    private protected readonly FakeDesktop Desktop = new();
    /// <summary>Over the pipe: the service's view of the shells, and the tray app's end serving them.</summary>
    protected readonly PipeSessionHost? PipeHost;
    protected PipeLink? TrayLink, ServiceLink;
    protected readonly PipeSessionServer? TrayServer;

    public ShellGateTests() : this(TimeSpan.FromSeconds(10)) { }

    protected ShellGateTests(bool overPipe) : this(TimeSpan.FromSeconds(10), overPipe) { }

    private ShellGateTests(TimeSpan handshakeTimeout, bool overPipe = false)
    {
        var transcripts = new TranscriptStore(_directory);
        _manager = new ShellSessionManager(transcripts,
            id => id switch { null or "pwsh" => new ShellCommand("pwsh", @"C:\pwsh.exe", []), "cmd" => new ShellCommand("cmd", @"C:\cmd.exe", []), _ => throw new ShellException(ShellError.BadRequest) },
            start => { var pty = new FakePty(start); lock (_ptys) _ptys.Add(pty); return pty; },
            () => new Dictionary<string, string>(), @"C:\Users\dev");
        _access.Record(new ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = KeyA, GrantedAt = DateTimeOffset.UtcNow });
        var hooks = new ShellGateHooks
        {
            MacInfo = () => new ShellEnvelope(ShellEnvelope.MacInfo) { IrohID = "endpoint-id" },
            Host = _ => new HostInfo { Kind = "windows", Os = "Windows 11 Pro", Shells = [new HostShell { Id = "pwsh", Name = "PowerShell", Default = true }] },
            State = _ => new HostState { Locked = false },
            Label = id => id == "phone-a" ? "iPhone" : id,
            Lock = id => _lock?.Invoke(id),
            Event = e => { lock (_events) _events.Add(e); },
            RemoteDesktop = Desktop,
            AccountOf = _ => "S-1-5-21-1",
        };
        var limiter = new HandshakeLimiter(handshakeTimeout, TimeProvider.System);
        if (overPipe)
        {
            // The same phones and the same answers, with the shells across the pipe as in the service.
            var local = new LocalSessionHost(_manager, transcripts);
            TrayServer = new PipeSessionServer(local, () => new PipeHostState(), () => null);
            PipeHost = new PipeSessionHost("S-1-5-21-test");
            _gate = new ShellGate(PipeHost, _access, limiter, hooks);
            PipeHost.Changed += () => _gate.PushSessions(PipeHost);
            LinkTray();
        }
        else _gate = new ShellGate(_manager, transcripts, _access, limiter, hooks);
        _listener.Start();
        _ = AcceptLoop();
    }

    /// <summary>Connects a tray app's end to the service's (again, after <see cref="CutTray"/>).</summary>
    protected void LinkTray()
    {
        var (tray, service) = Pipe.DuplexStreams.Create();
        TrayLink = new PipeLink(tray, service: false, PipeSessionServer.LinkBacklogLimit);
        ServiceLink = new PipeLink(service, service: true, 4 << 20);
        var serviceLink = ServiceLink;
        PipeHost!.Link(serviceLink);
        _ = Task.Run(async () =>
        {
            await serviceLink.RunAsync(PipeHost.OnFrameAsync);
            PipeHost.Unlink(serviceLink);
        });
        _ = Task.Run(() => TrayServer!.ServeAsync(TrayLink));
    }

    /// <summary>The tray app crashes: its end of the pipe goes.</summary>
    protected void CutTray() => TrayLink!.Close();

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _gate.Stop();
        _listener.Stop();
        _manager.CloseAll();
        await Task.Yield();
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private async Task AcceptLoop()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch (Exception) { return; }
            _ = _gate.ServeAsync(client.GetStream(), "127.0.0.1");
        }
    }

    private FakePty Pty() { lock (_ptys) return _ptys[^1]; }

    private protected void AllowScreen() => _access.SetScreenAllowed("phone-a", true);

    /// <summary>
    /// Remote Desktop behind the relay: a duplex stream whose far end answers the X.224 request with
    /// <see cref="Selected"/>, then echoes.
    /// </summary>
    private protected sealed class FakeDesktop : Passthrough.Core.Screen.IRemoteDesktopGate
    {
        public Passthrough.Core.Screen.RelayVerdict Verdict = Passthrough.Core.Screen.RelayVerdict.No("service");
        public bool Genuine = true;
        public uint Selected = 2;
        public string Pin = new('a', 64);
        public int Dials;

        public Task<Passthrough.Core.Screen.RelayVerdict> CheckAsync(string? account, CancellationToken cancel) => Task.FromResult(Verdict);

        public Task<Stream?> DialAsync(int port, CancellationToken cancel)
        {
            Interlocked.Increment(ref Dials);
            if (!Genuine) return Task.FromResult<Stream?>(null);
            var (ours, theirs) = Pipe.DuplexStreams.Create();
            _ = Task.Run(async () =>
            {
                var request = new byte[19];
                await theirs.ReadExactlyAsync(request);
                await theirs.WriteAsync(global::Passthrough.Core.Tests.Screen.ScreenTests.Confirm(Selected));
                var buffer = new byte[4096];
                int n;
                try { while ((n = await theirs.ReadAsync(buffer)) > 0) await theirs.WriteAsync(buffer.AsMemory(0, n)); }
                catch (Exception e) when (e is IOException or ObjectDisposedException) { }
            });
            return Task.FromResult<Stream?>(ours);
        }

        public Task<string?> CertificateSha256Async(CancellationToken cancel) => Task.FromResult<string?>(Pin);
    }

    /// <summary>A phone's end of a connection.</summary>
    private protected sealed class Phone : IDisposable
    {
        private readonly TcpClient _client = new();
        private ShellLineReader _reader = null!;
        private NetworkStream _stream = null!;

        public static async Task<Phone> Connect(int port)
        {
            var phone = new Phone();
            await phone._client.ConnectAsync(IPAddress.Loopback, port);
            phone._stream = phone._client.GetStream();
            phone._reader = new ShellLineReader(phone._stream, RemoteShell.LineLimit * 2);
            return phone;
        }

        public Task Send(string json) => _stream.WriteAsync(Encoding.UTF8.GetBytes(json + "\n")).AsTask();

        /// <summary>After <c>rdpReady</c>: the connection is Remote Desktop's bytes.</summary>
        public NetworkStream Raw => _stream;
        public Task Send(ShellEnvelope e) => _stream.WriteAsync(e.EncodeLine()).AsTask();

        public async Task<ShellEnvelope?> Next()
        {
            byte[]? line;
            // A host that hangs up with lines unread resets the connection: that is it ending too.
            try { line = await _reader.ReadLineAsync().WaitAsync(Patience); }
            catch (IOException) { return null; }
            return line is null ? null : ShellEnvelope.Decode(line);
        }

        public async Task<string?> NextRaw()
        {
            var line = await _reader.ReadLineAsync().WaitAsync(Patience);
            return line is null ? null : Encoding.UTF8.GetString(line);
        }

        /// <summary>The next message of type <paramref name="type"/>, skipping others.</summary>
        public async Task<ShellEnvelope> Next(string type)
        {
            while (true)
            {
                var message = await Next() ?? throw new IOException($"closed before {type}");
                if (message.T == type) return message;
            }
        }

        public async Task<ShellEnvelope?> Prove(string phoneId, byte[] key, bool hello = true)
        {
            if (hello) await Send(new ShellEnvelope(ShellEnvelope.Hello) { PhoneID = phoneId });
            var challenge = await Next();
            Assert.Equal(ShellEnvelope.Challenge, challenge?.T);
            var proof = RemoteShell.Proof(key, Convert.FromBase64String(challenge!.Nonce!));
            await Send(new ShellEnvelope(ShellEnvelope.Proof) { PhoneID = phoneId, Mac = Convert.ToBase64String(proof) });
            return await Next();
        }

        /// <summary>Reads past anything still queued until the connection ends: null then.</summary>
        public async Task<ShellEnvelope?> NextOrNullAfterOthers()
        {
            while (await Next() is not null) { }
            return null;
        }

        public void Dispose() => _client.Dispose();
    }

    private int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    private protected async Task<Phone> Proven(string phoneId = "phone-a", byte[]? key = null)
    {
        var phone = await Phone.Connect(Port);
        Assert.Equal(ShellEnvelope.Ready, (await phone.Prove(phoneId, key ?? KeyA))?.T);
        Assert.Equal(ShellEnvelope.MacInfo, (await phone.Next())?.T);
        Assert.Equal(ShellEnvelope.Host, (await phone.Next())?.T);
        Assert.Equal(ShellEnvelope.MacState, (await phone.Next())?.T);
        Assert.Equal(ShellEnvelope.Sessions, (await phone.Next())?.T);
        return phone;
    }

    [Fact]
    public async Task AProvenPhoneHearsReadyThenTheHostInOrder()
    {
        var phone = await Phone.Connect(Port);
        Assert.Equal(ShellEnvelope.Ready, (await phone.Prove("phone-a", KeyA))?.T);
        Assert.Equal("endpoint-id", (await phone.Next())?.IrohID);
        var host = await phone.Next();
        Assert.Equal("windows", host?.HostInfo?.Kind);
        Assert.Equal(ShellEnvelope.MacState, (await phone.Next())?.T);
        Assert.Empty((await phone.Next())!.SessionList!);
        await phone.Send("{\"t\":\"ping\"}");
        // Over the pipe the session list can be pushed again as the service's snapshot arrives: that is allowed.
        var next = await phone.Next();
        while (next?.T == ShellEnvelope.Sessions) next = await phone.Next();
        Assert.Equal(ShellEnvelope.Pong, next?.T);
        Assert.Equal(["phone-a"], _gate.ConnectedPhones);
    }

    [Theory]
    [InlineData("phone-a", false)]
    [InlineData("stranger", true)]
    public async Task AWrongKeyOrAnUnknownPhoneIsRefused(string phoneId, bool rightKey)
    {
        var phone = await Phone.Connect(Port);
        var answer = await phone.Prove(phoneId, rightKey ? KeyA : new byte[32]);
        Assert.Equal(ShellEnvelope.Error, answer?.T);
        Assert.Equal("not_authorized", answer?.Reason);
        Assert.Null(await phone.Next());
        Assert.Empty(_gate.ConnectedPhones);
    }

    [Fact]
    public async Task AConnectionThatDoesNotSayHelloIsDropped()
    {
        var phone = await Phone.Connect(Port);
        await phone.Send("{\"t\":\"list\"}");
        Assert.Null(await phone.Next());
    }

    [Fact]
    public async Task ThePreviousKeyWorksUntilTheNewOneIsProved()
    {
        var keyB = Enumerable.Repeat((byte)9, 32).ToArray();
        _access.Record(new ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = keyB, GrantedAt = DateTimeOffset.UtcNow });
        using (var old = await Proven(key: KeyA)) { }
        using (var renewed = await Proven(key: keyB)) { }
        Assert.True(SpinWait.SpinUntil(() => _access.CandidateKeys("phone-a").Count == 1, 5000), "the previous key is retired");
        var phone = await Phone.Connect(Port);
        Assert.Equal("not_authorized", (await phone.Prove("phone-a", KeyA))?.Reason);
    }

    [Fact]
    public async Task OpeningAShellAnswersWithItsRefThenStreamsIt()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24,\"ref\":5}");
        // Sent before `opened` (the keyboard coming up): it reaches the new session.
        await phone.Send("{\"t\":\"resize\",\"cols\":60,\"rows\":20}");
        var opened = await phone.Next(ShellEnvelope.Opened);
        Assert.Equal(5, opened.Ref);
        var id = opened.Session!;
        Assert.Equal(ShellEnvelope.Replaying, (await phone.Next(ShellEnvelope.Replaying)).T);
        Assert.Equal(id, (await phone.Next(ShellEnvelope.Attached)).Session);
        Assert.True(SpinWait.SpinUntil(() => Pty().Sizes.Contains((60, 20)), 5000));
        Pty().Print("PS C:\\> ");
        var output = await phone.Next(ShellEnvelope.Output);
        Assert.Equal("PS C:\\> ", Encoding.UTF8.GetString(Convert.FromBase64String(output.Data!)));
        await phone.Send(new ShellEnvelope(ShellEnvelope.Input) { Session = id, Data = Convert.ToBase64String("dir\r"u8) });
        Assert.True(SpinWait.SpinUntil(() => Pty().Written == "dir\r", 5000));
        Pty().Exit(0);
        var ended = await phone.Next(ShellEnvelope.Ended);
        Assert.Equal(0, ended.ExitStatus);
        Assert.Contains("iPhone opened a session", _events);
    }

    [Fact]
    public async Task TheChosenShellStarts_AndOneThePcHasntIsRefused()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24,\"shell\":\"cmd\",\"ref\":1}");
        await phone.Next(ShellEnvelope.Opened);
        Assert.Equal(@"C:\cmd.exe", Pty().StartInfo.Executable);
        Assert.Equal("cmd", _manager.Sessions.Single().Shell);
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24,\"shell\":\"evil\",\"ref\":2}");
        var refused = await phone.Next(ShellEnvelope.Error);
        Assert.Equal(("bad_request", 2), (refused.Reason, refused.Ref));
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24,\"shell\":\"C:\\\\x.exe\",\"ref\":3}");
        Assert.Equal(3, (await phone.Next(ShellEnvelope.Error)).Ref);
    }

    [Fact]
    public async Task ASecondPhoneTakesASessionOver()
    {
        _access.Record(new ShellPhone { PhoneId = "phone-b", Label = "iPad", PairingSlot = "token.ipad.B", Key = KeyA, GrantedAt = DateTimeOffset.UtcNow });
        using var first = await Proven();
        await first.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24}");
        var id = (await first.Next(ShellEnvelope.Opened)).Session!;
        await first.Next(ShellEnvelope.Attached);
        using var second = await Proven("phone-b");
        await second.Send($"{{\"t\":\"attach\",\"session\":\"{id}\",\"cols\":100,\"rows\":30}}");
        await second.Next(ShellEnvelope.Attached);
        Assert.Equal(id, (await first.Next(ShellEnvelope.Detached)).Session);
        await first.Send(new ShellEnvelope(ShellEnvelope.Input) { Session = id, Data = Convert.ToBase64String("x"u8) });
        Assert.Equal("bad_request", (await first.Next(ShellEnvelope.Error)).Reason);
    }

    [Fact]
    public async Task APcAnswersWhatOnlyAMacDoesAsTheFixturesSay()
    {
        using var phone = await Proven();
        foreach (var pair in Fixtures.Root.GetProperty("shell").GetProperty("pcAnswers").EnumerateArray())
        {
            await phone.Send(pair.GetProperty("request").GetString()!);
            var answer = await phone.NextRaw();
            Assert.True(Fixtures.JsonEqual(pair.GetProperty("answer").GetString()!, answer!), $"{pair.GetProperty("request")} -> {answer}");
        }
    }

    [Fact]
    public async Task EvenAScreenAllowedPhoneGetsNoMacScreen_AndRdpWaitsForTheService()
    {
        _access.SetScreenAllowed("phone-a", true);
        using var phone = await Proven();
        await phone.Send("{\"t\":\"screen\"}");
        Assert.Equal("screen_not_allowed", (await phone.Next(ShellEnvelope.Error)).Reason);
        await phone.Send("{\"t\":\"screenVideo\"}");
        Assert.Equal("screen_not_allowed", (await phone.Next(ShellEnvelope.Error)).Reason);
        await phone.Send("{\"t\":\"rdp\"}");
        var rdp = await phone.Next(ShellEnvelope.Error);
        Assert.Equal(("rdp_unavailable", "service"), (rdp.Reason, rdp.Detail));
    }

    [Fact]
    public async Task LockIsAnsweredWithTheStateOrWhyNot()
    {
        using var phone = await Proven();
        _lock = _ => null;
        await phone.Send("{\"t\":\"lock\"}");
        Assert.Equal(ShellEnvelope.MacState, (await phone.Next())?.T);
        _lock = _ => ShellError.NotAllowed;
        await phone.Send("{\"t\":\"lock\"}");
        Assert.Equal("not_allowed", (await phone.Next())?.Reason);
    }

    [Fact]
    public async Task HistoryAndATranscriptAreSent()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24}");
        var id = (await phone.Next(ShellEnvelope.Opened)).Session!;
        Pty().Print("hello transcript");
        await phone.Send("{\"t\":\"history\"}");
        var history = await phone.Next(ShellEnvelope.HistoryList);
        Assert.Equal(id, history.HistoryEntries!.Single().Id);
        await phone.Send($"{{\"t\":\"transcript\",\"session\":\"{id}\"}}");
        var data = await phone.Next(ShellEnvelope.TranscriptData);
        Assert.Equal((80, 24), (data.Cols, data.Rows));
        Assert.Contains("hello transcript", Encoding.UTF8.GetString(Convert.FromBase64String(data.Data!)));
        Assert.True(data.Done);
        await phone.Send("{\"t\":\"transcript\",\"session\":\"..\\\\x\"}");
        Assert.Equal("no_such_session", (await phone.Next(ShellEnvelope.Error)).Reason);
    }

    [Fact]
    public async Task ARevokedPhoneIsCutOffAndItsSessionsEnd()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24}");
        await phone.Next(ShellEnvelope.Opened);
        _access.Revoke("phone-a");
        _gate.Disconnect("phone-a");
        Assert.Null(await phone.NextOrNullAfterOthers());
        // Across the pipe the shells end a moment later, once the tray app hears of it.
        await Eventually(() => !_manager.Sessions.Single().Running);
    }

    private static async Task Eventually(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Patience;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) Assert.Fail("never happened");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task AnOverlongLineEndsTheConnection()
    {
        using var phone = await Proven();
        await phone.Send(new string('x', RemoteShell.LineLimit + 10));
        Assert.Null(await phone.NextOrNullAfterOthers());
    }

    [Fact]
    public async Task ASilentAttemptIsDroppedAtTheHandshakeTimeout()
    {
        await using var quick = new ShellGateTests(TimeSpan.FromMilliseconds(300));
        var phone = await Phone.Connect(quick.Port);
        Assert.Null(await phone.Next());
        Assert.Equal(0, quick._gate.PendingHandshakes);
    }

    [Fact]
    public async Task SessionsArePushedAndGoingAwayIsSaid()
    {
        using var phone = await Proven();
        _manager.Open("Mac", 80, 24);
        // Across the pipe the service's list follows the tray app's a moment later.
        await Eventually(() => _gate.ConnectedPhones.Count == 1 && (PipeHost?.Sessions.Count ?? 1) == 1);
        _gate.PushSessions();
        while ((await phone.Next(ShellEnvelope.Sessions)).SessionList!.Count == 0) { }
        await _gate.GoingAwayAsync("sleeping");
        Assert.Equal("sleeping", (await phone.Next(ShellEnvelope.GoingAway)).Reason);
    }

    [Fact]
    public async Task GoingAwaySaysWhyThenCloses()
    {
        using var phone = await Proven();
        await _gate.GoingAwayAsync("shutting_down", TimeSpan.FromSeconds(2), close: true);
        Assert.Equal("shutting_down", (await phone.Next(ShellEnvelope.GoingAway)).Reason);
        Assert.Null(await phone.NextOrNullAfterOthers());
        // Still accepting: a PC that wakes takes phones again.
        using var again = await Proven();
    }
}
