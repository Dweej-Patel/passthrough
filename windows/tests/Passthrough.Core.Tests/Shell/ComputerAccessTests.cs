using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>Stage 7 (a) on a PC host: a phone gives a computer access, and the computer proves its key and its identity.</summary>
public sealed class ComputerAccessTests : IAsyncDisposable
{
    private const string Account = "S-1-5-21-1-2-3-1001";
    private static readonly byte[] PhoneKey = Enumerable.Repeat((byte)9, 32).ToArray();
    private static readonly ProofBinding Binding = new(ComputerProof.PathTls, Enumerable.Repeat((byte)0xAB, 32).ToArray());
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"ComputerAccessTests-{Guid.NewGuid():N}");
    private readonly AccessDirectory _access = new(new MemorySecretStore());
    private readonly ShellSessionManager _manager;
    private readonly ShellGate _gate;
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly ECDsa _identity = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly List<(string, ShellComputer)> _granted = [];

    public ComputerAccessTests()
    {
        var transcripts = new TranscriptStore(_directory);
        _manager = new ShellSessionManager(transcripts, _ => new ShellCommand("cmd", @"C:\cmd.exe", []), start => new FakePty(start),
            () => new Dictionary<string, string>(), @"C:\Users\dev");
        _access.Add(Account, new ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = PhoneKey, GrantedAt = DateTimeOffset.UtcNow });
        var host = new LocalSessionHost(_manager, transcripts);
        // As on the service: an id with no owner (revoked) reaches an account with no shells, never this one.
        var nobody = new LocalSessionHost(new ShellSessionManager(transcripts, _ => null!, start => new FakePty(start),
            () => new Dictionary<string, string>(), @"C:\Users\dev"), transcripts);
        _gate = new ShellGate(id => _access.Owner(id) is null ? nobody : host, _access, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), new ShellGateHooks
        {
            Host = _ => new HostInfo { Kind = "windows", Shells = [new HostShell { Id = "cmd", Name = "Command Prompt", Default = true }] },
            State = _ => new HostState { Control = false },
            ComputerGranted = (phone, c) => { lock (_granted) _granted.Add((phone, c)); },
        });
        // As the service does: a change to an account's phones or computers reaches the phones that asked.
        _access.Changed += _ => _gate.PushComputers();
        _listener.Start();
        _ = Task.Run(async () =>
        {
            while (!_stop.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(_stop.Token); } catch (Exception) { return; }
                var stream = client.GetStream();
                if (_gate.Admit("127.0.0.1", stream.Dispose) is { } admission) _ = _gate.ServeAsync(admission, stream, expectHello: true, Binding);
            }
        });
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _gate.Stop();
        _listener.Stop();
        _manager.CloseAll();
        _identity.Dispose();
        await Task.Yield();
        try { Directory.Delete(_directory, true); } catch (IOException) { }
    }

    private byte[] IdKey()
    {
        var q = _identity.ExportParameters(false).Q;
        return [0x04, .. q.X!, .. q.Y!];
    }

    private sealed class Line(TcpClient client)
    {
        private readonly ShellLineReader _reader = new(client.GetStream(), RemoteShell.LineLimit * 2);
        public Task Send(ShellEnvelope e) => client.GetStream().WriteAsync(e.EncodeLine()).AsTask();

        public async Task<ShellEnvelope?> Next()
        {
            try { return await _reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)) is { } l ? ShellEnvelope.Decode(l) : null; }
            catch (IOException) { return null; }
        }

        public async Task<ShellEnvelope> Next(string t)
        {
            while (await Next() is { } m) if (m.T == t || m.T == ShellEnvelope.Error) return m;
            throw new IOException("closed");
        }
    }

    /// <summary>Connects as <paramref name="id"/>: hello, the challenge, the HMAC proof and, for a computer, the signature.</summary>
    private async Task<Line> Connect(string id, byte[] key, Func<byte[], string?>? sign = null)
    {
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)_listener.LocalEndpoint).Port);
        var line = new Line(client);
        await line.Send(new ShellEnvelope(ShellEnvelope.Hello) { PhoneID = id });
        var nonce = Convert.FromBase64String((await line.Next(ShellEnvelope.Challenge)).Nonce!);
        await line.Send(new ShellEnvelope(ShellEnvelope.Proof)
        {
            PhoneID = id,
            Mac = Convert.ToBase64String(RemoteShell.Proof(key, nonce)),
            Sig = sign?.Invoke(nonce),
        });
        return line;
    }

    private Func<byte[], string?> Signer(string id, ProofBinding binding) => nonce =>
        Convert.ToBase64String(_identity.SignData(ComputerProof.Message(nonce, binding.Path, binding.HostBinding, id), HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation));

    private async Task<ShellEnvelope> Grant(params string[] scopes)
    {
        var phone = await Connect("phone-a", PhoneKey);
        await phone.Next(ShellEnvelope.Ready);
        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerGrant)
        {
            Name = "MacBook", Viewer = "mac-host-id", Scopes = [.. scopes], IdKey = Convert.ToBase64String(IdKey()), Kind = "mac",
        });
        return await phone.Next(ShellEnvelope.ComputerGranted);
    }

    [Fact]
    public async Task APhoneThatMayShareGivesAComputerTheShell()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var granted = await Grant("shell");
        Assert.Equal(ShellEnvelope.ComputerGranted, granted.T);
        Assert.StartsWith("computer.", granted.PhoneID, StringComparison.Ordinal);
        Assert.Equal(["shell"], granted.Scopes);
        Assert.Single(_granted);

        var id = granted.PhoneID!;
        var computer = await Connect(id, Convert.FromBase64String(granted.Key!), Signer(id, Binding));
        Assert.Equal(ShellEnvelope.Ready, (await computer.Next())?.T);
        Assert.Contains((await computer.Next(ShellEnvelope.Host)).HostInfo!.Shells!, s => s.Id == "cmd");
        await computer.Next(ShellEnvelope.Sessions);
        await computer.Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = 80, Rows = 24, Ref = 1 });
        Assert.Equal(ShellEnvelope.Opened, (await computer.Next(ShellEnvelope.Opened)).T);
        // Nothing a computer may not ask (stage 7 a.3): no history, no lock, no onward grant.
        foreach (var t in new[] { ShellEnvelope.History, ShellEnvelope.Lock, ShellEnvelope.ComputerGrant })
        {
            await computer.Send(new ShellEnvelope(t));
            Assert.Equal("not_allowed", (await computer.Next(ShellEnvelope.Error)).Reason);
        }
    }

    [Fact]
    public async Task ACopiedCredentialOpensNothingWithoutTheIdentityKey()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var granted = await Grant("shell");
        var id = granted.PhoneID!;
        var key = Convert.FromBase64String(granted.Key!);
        Assert.Equal("not_authorized", (await (await Connect(id, key)).Next())?.Reason);                  // no signature
        using var other = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var forged = await Connect(id, key, nonce => Convert.ToBase64String(other.SignData(
            ComputerProof.Message(nonce, Binding.Path, Binding.HostBinding, id), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)));
        Assert.Equal("not_authorized", (await forged.Next())?.Reason);                                     // another key
        var elsewhere = new ProofBinding(ComputerProof.PathTls, new byte[32]);
        Assert.Equal("not_authorized", (await (await Connect(id, key, Signer(id, elsewhere))).Next())?.Reason); // bound to another host
    }

    [Fact]
    public async Task APhoneMayOnlyShareWhenTheOwnerLetsIt()
    {
        Assert.Equal("not_allowed", (await Grant("shell")).Reason);
        _access.For(Account).SetShareAllowed("phone-a", true);
        Assert.Equal("screen_not_allowed", (await Grant("screen")).Reason); // the phone itself can't see the screen
    }

    [Fact]
    public async Task OnAPcTheScreenWaitsForTheOwner()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        _access.For(Account).SetScreenAllowed("phone-a", true);
        var granted = await Grant("shell", "screen");
        Assert.Equal(["shell"], granted.Scopes);
        Assert.Equal(["screen"], granted.Pending);
        Assert.False(_access.ScreenAllowed(granted.PhoneID!));
    }

    [Fact]
    public async Task RemovingThePhoneRemovesWhatItGranted()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var id = (await Grant("shell")).PhoneID!;
        Assert.NotNull(_access.Computer(id));
        _access.For(Account).Revoke("phone-a");
        Assert.Null(_access.Computer(id));
    }

    [Fact]
    public async Task EightComputersAPhoneAndThenRefused()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var phone = await Connect("phone-a", PhoneKey);
        await phone.Next(ShellEnvelope.Ready);
        for (var i = 0; i <= Computers.MaxPerGranter; i++)
        {
            await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerGrant)
            {
                Name = $"Mac {i}", Viewer = $"viewer-{i}", Scopes = ["shell"], IdKey = Convert.ToBase64String(IdKey()),
            });
            var answer = await phone.Next(ShellEnvelope.ComputerGranted);
            Assert.Equal(i < Computers.MaxPerGranter ? ShellEnvelope.ComputerGranted : ShellEnvelope.Error, answer.T);
            if (i == Computers.MaxPerGranter) Assert.Equal("too_many_computers", answer.Reason);
        }
    }

    [Fact]
    public async Task APhoneTakesBackOneItCouldntHandOver()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var phone = await Connect("phone-a", PhoneKey);
        await phone.Next(ShellEnvelope.Ready);
        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerGrant) { Name = "MacBook", Viewer = "v", Scopes = ["shell"], IdKey = Convert.ToBase64String(IdKey()) });
        var id = (await phone.Next(ShellEnvelope.ComputerGranted)).PhoneID!;
        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerRevoke) { PhoneID = id });
        Assert.Equal(ShellEnvelope.ComputerRevoked, (await phone.Next(ShellEnvelope.ComputerRevoked)).T);
        Assert.Null(_access.Computer(id));
    }

    [Fact]
    public async Task APhoneHearsTheComputersItGaveAccessToAndEachChange()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var phone = await Connect("phone-a", PhoneKey);
        await phone.Next(ShellEnvelope.Ready);
        await phone.Send(new ShellEnvelope(ShellEnvelope.ListComputers));
        Assert.Empty((await phone.Next(ShellEnvelope.ComputerList)).Computers!);

        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerGrant) { Name = "Mac\u0007Book", Viewer = "v", Scopes = ["shell"], IdKey = Convert.ToBase64String(IdKey()), Kind = "mac" });
        // The store's change is heard as it is written, before the grant's answer.
        var entry = Assert.Single((await phone.Next(ShellEnvelope.ComputerList)).Computers!);
        var id = (await phone.Next(ShellEnvelope.ComputerGranted)).PhoneID!;
        Assert.Equal((id, "v", "MacBook", "mac", false), (entry.PhoneID, entry.Viewer, entry.Name, entry.Kind, entry.Connected));
        Assert.Equal(["shell"], entry.Scopes);
        Assert.Null(entry.Pending);

        // The computer connects: the phone hears it; the computer itself may not ask.
        var computer = await Connect(id, Convert.FromBase64String((await GrantKey(id))), Signer(id, Binding));
        await computer.Next(ShellEnvelope.Ready);
        Assert.True(Assert.Single((await phone.Next(ShellEnvelope.ComputerList)).Computers!).Connected);
        await computer.Send(new ShellEnvelope(ShellEnvelope.ListComputers));
        Assert.Equal("not_allowed", (await computer.Next(ShellEnvelope.Error)).Reason);

        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerRevoke) { PhoneID = id });
        Assert.Empty((await phone.Next(ShellEnvelope.ComputerList)).Computers!);
    }

    [Fact]
    public async Task AnotherPhonesComputersArentListed()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        await Grant("shell");
        _access.Add(Account, new ShellPhone { PhoneId = "phone-b", Label = "iPad", PairingSlot = "token.ipad.B", Key = PhoneKey, GrantedAt = DateTimeOffset.UtcNow });
        var other = await Connect("phone-b", PhoneKey);
        await other.Next(ShellEnvelope.Ready);
        await other.Send(new ShellEnvelope(ShellEnvelope.ListComputers));
        Assert.Empty((await other.Next(ShellEnvelope.ComputerList)).Computers!);
    }

    /// <summary>The key a computer was given, from the store (the grant's answer went to the phone).</summary>
    private Task<string> GrantKey(string id) => Task.FromResult(Convert.ToBase64String(_access.ComputersFor(Account).Find(id)!.Key));

    [Fact]
    public async Task ARevokedComputersShellsEnd()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var phone = await Connect("phone-a", PhoneKey);
        await phone.Next(ShellEnvelope.Ready);
        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerGrant) { Name = "MacBook", Viewer = "v", Scopes = ["shell"], IdKey = Convert.ToBase64String(IdKey()) });
        var granted = await phone.Next(ShellEnvelope.ComputerGranted);
        var id = granted.PhoneID!;
        var computer = await Connect(id, Convert.FromBase64String(granted.Key!), Signer(id, Binding));
        await computer.Next(ShellEnvelope.Sessions);
        await computer.Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = 80, Rows = 24, Ref = 1 });
        await computer.Next(ShellEnvelope.Opened);
        Assert.Equal(1, _manager.RunningSessions(id));

        await phone.Send(new ShellEnvelope(ShellEnvelope.ComputerRevoke) { PhoneID = id });
        await phone.Next(ShellEnvelope.ComputerRevoked);
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (_manager.RunningSessions(id) > 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
        Assert.Equal(0, _manager.RunningSessions(id));
    }

    private sealed class Identity(ECDsa key) : Passthrough.Core.Trust.IComputerIdentity
    {
        public byte[] PublicKey { get { var q = key.ExportParameters(false).Q; return [0x04, .. q.X!, .. q.Y!]; } }
        public byte[] Sign(byte[] message) => key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    /// <summary>TCP standing in for TLS: the gate here binds signatures to a fixed "certificate hash".</summary>
    private sealed class PlainDialer : Passthrough.Core.Client.IPinnedTlsDialer
    {
        public async Task<Passthrough.Core.Client.IShellStream> ConnectAsync(Passthrough.Core.Client.ShellEndpoint endpoint, string certSha256, CancellationToken cancel)
        {
            var client = new TcpClient();
            await client.ConnectAsync(endpoint.Host, endpoint.Port, cancel);
            return new Plain(client);
        }

        private sealed class Plain(TcpClient client) : Passthrough.Core.Client.IShellStream
        {
            public Stream Stream => client.GetStream();
            public IPAddress? LocalAddress => null;
            public ValueTask DisposeAsync() { client.Dispose(); return ValueTask.CompletedTask; }
        }
    }

    [Fact]
    public async Task ThisPcsOwnClientConnectsAsAComputerAndSignsItsProof()
    {
        _access.For(Account).SetShareAllowed("phone-a", true);
        var granted = await Grant("shell");
        // On TLS the host speaks first: the client sends no hello, so the gate here must not expect one.
        var tcp = new TcpListener(IPAddress.Loopback, 0);
        tcp.Start();
        _ = Task.Run(async () =>
        {
            var c = await tcp.AcceptTcpClientAsync();
            if (_gate.Admit("127.0.0.1", c.Dispose) is { } admission) await _gate.ServeAsync(admission, c.GetStream(), expectHello: false, Binding);
        });
        var credential = new Passthrough.Core.Client.ShellCredential("host", "PC", Convert.ToHexStringLower(Binding.HostBinding), Convert.FromBase64String(granted.Key!),
            granted.PhoneID!, ((IPEndPoint)tcp.LocalEndpoint).Port, ["127.0.0.1"]);
        var events = System.Threading.Channels.Channel.CreateUnbounded<Passthrough.Core.Client.ShellClientEvent>();
        await using var client = new Passthrough.Core.Client.ShellClient(credential, new PlainDialer(), null, e => events.Writer.TryWrite(e),
            Passthrough.Core.Client.ShellConnectMode.LocalOnly, identity: new Identity(_identity));
        client.Connect();
        var first = await events.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.IsType<Passthrough.Core.Client.ShellClientEvent.Ready>(first);
        tcp.Stop();
    }

    [Fact]
    public void TheDecoyIsARealPoint() => Assert.False(ComputerProof.IsValid(new byte[64], ComputerProof.DecoyKey, "x"u8));

    [Fact]
    public void TheDecoySignatureIsWellFormedButNeverValid() =>
        Assert.False(ComputerProof.IsValid(ComputerProof.DecoySignature, ComputerProof.DecoyKey, "x"u8));

    private ShellComputer GrantMac(string viewer = "mac-1")
    {
        Assert.True(_access.For(Account).SetShareAllowed("phone-a", true));
        var (c, error) = _access.GrantComputer("phone-a", "MacBook", viewer, "mac", IdKey(), new HashSet<string> { "shell" }, screenNeedsOwner: false);
        Assert.Null(error);
        return c!;
    }

    [Fact]
    public void RevokingAPhoneTakesItsComputersWithIt()
    {
        var c = GrantMac();
        var cut = new List<string>();
        var admin = new Passthrough.Core.Pipe.PipeAdminHandler(_access, () => null, _ => 0, cut.Add);
        var reply = admin.Handle(Account, new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.Revoke, Phone = "phone-a" });
        Assert.Null(reply.Error);
        Assert.Empty(_access.ComputersFor(Account).All);
        Assert.Contains("phone-a", cut);
        Assert.Contains(c.Id, cut);
    }

    [Fact]
    public void TheOwnerCanRevokeAComputer()
    {
        var c = GrantMac();
        var cut = new List<string>();
        var admin = new Passthrough.Core.Pipe.PipeAdminHandler(_access, () => null, _ => 0, cut.Add);
        Assert.Null(admin.Handle(Account, new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.RevokeComputer, Phone = c.Id }).Error);
        Assert.Null(_access.Computer(c.Id));
        Assert.Equal([c.Id], cut);
        // Another account can't name it.
        Assert.Equal(Passthrough.Core.Pipe.PipeAdminReply.Unknown,
            admin.Handle("S-1-5-21-9", new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.RevokeComputer, Phone = c.Id }).Error);
    }

    [Fact]
    public void ANewGrantForTheSameComputerCutsTheOldOne()
    {
        var replaced = new List<string>();
        _access.Replaced += replaced.Add;
        var first = GrantMac();
        var second = GrantMac();
        Assert.Equal([first.Id], replaced);
        Assert.Null(_access.Computer(first.Id));
        Assert.NotNull(_access.Computer(second.Id));
    }

    [Fact]
    public void SettingsListsAComputerAndItsScreenCanBeAllowedThenMadeToWaitAgain()
    {
        Assert.True(_access.For(Account).SetShareAllowed("phone-a", true));
        Assert.True(_access.For(Account).SetScreenAllowed("phone-a", true));
        var (c, error) = _access.GrantComputer("phone-a", "MacBook", "mac-1", "mac", IdKey(), new HashSet<string> { "shell", "screen" }, screenNeedsOwner: true);
        Assert.Null(error);
        var ended = new List<string>();
        var admin = new Passthrough.Core.Pipe.PipeAdminHandler(_access, () => null, _ => 0, _ => { }) { EndScreen = (id, _) => ended.Add(id) };
        Passthrough.Core.Pipe.PipeComputer Listed() =>
            Assert.Single(admin.Handle(Account, new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.List }).Computers!);

        Assert.Equal(("MacBook", "mac", true, false, true), (Listed().Name, Listed().Kind, Listed().Shell, Listed().Screen, Listed().ScreenPending));
        var allow = new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.AllowComputerScreen, Phone = c!.Id };
        Assert.Null(admin.Handle(Account, allow).Error);
        Assert.Equal((true, false), (Listed().Screen, Listed().ScreenPending));
        // Off: it waits for the owner again, and its views end now.
        Assert.Null(admin.Handle(Account, allow with { On = false }).Error);
        Assert.Equal((false, true), (Listed().Screen, Listed().ScreenPending));
        Assert.Equal([c.Id], ended);
        Assert.Null(admin.Handle(Account, allow).Error);
        Assert.True(Listed().Screen);
    }

    [Fact]
    public void TheFlyoutSeesWhoIsViewingAndCanStopAComputer()
    {
        Assert.True(_access.For(Account).SetShareAllowed("phone-a", true));
        var (c, error) = _access.GrantComputer("phone-a", "MacBook", "mac-1", "mac", IdKey(), new HashSet<string> { "shell" }, screenNeedsOwner: true);
        Assert.Null(error);
        var cut = new List<string>();
        var admin = new Passthrough.Core.Pipe.PipeAdminHandler(_access, () => null, _ => 1, cut.Add) { Viewing = id => id == c!.Id };
        var list = admin.Handle(Account, new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.List });
        Assert.False(Assert.Single(list.Devices!).Viewing);
        Assert.True(Assert.Single(list.Computers!).Viewing);

        // Stop in the flyout's Remote tab works for a computer of this account, not for one of another's.
        var stop = new Passthrough.Core.Pipe.PipeAdminRequest { Op = Passthrough.Core.Pipe.PipeAdminRequest.Disconnect, Phone = c!.Id };
        Assert.Null(admin.Handle(Account, stop).Error);
        Assert.Equal([c.Id], cut);
        Assert.Equal(Passthrough.Core.Pipe.PipeAdminReply.Unknown, admin.Handle("S-1-5-21-9-9-9-1001", stop).Error);
    }

    [Fact]
    public void AReplacedGrantsNoticesGo()
    {
        var board = new Passthrough.Core.Pipe.NoticeBoard();
        board.Add(Account, Passthrough.Core.Pipe.PipeNotice.ComputerScreenPending, "old", "computer.old");
        board.Add(Account, Passthrough.Core.Pipe.PipeNotice.ComputerScreenPending, "new", "computer.new");
        board.Forget("computer.old");
        Assert.Equal(["new"], board.For(Account).Select(n => n.Text));
    }

    [Fact]
    public void ADisallowedAccountsPhonesReachNothing()
    {
        Assert.Equal(Account, _access.Owner("phone-a"));
        _access.IsAllowed = a => a != Account;
        Assert.Null(_access.Owner("phone-a"));
    }
}
