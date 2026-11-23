using System.Text;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Shell;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>A phone opening a real shell on this PC over iroh, relays off: everything but the phone app.</summary>
public sealed class IrohShellListenerTests : IDisposable
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);
    private static readonly byte[] Key = Enumerable.Repeat((byte)3, 32).ToArray();
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"IrohShellListenerTests-{Guid.NewGuid():N}");
    private readonly IrohEndpoint _host = IrohEndpoint.Bind(IrohEndpoint.NewSecretKey(), IrohRelay.None, IrohEndpoint.ShellAlpn);
    private readonly IrohEndpoint _phone = IrohEndpoint.Bind([], IrohRelay.None);
    private readonly ShellSessionManager _manager;
    private readonly ShellGate _gate;
    private readonly IrohShellListener _listener;

    public IrohShellListenerTests()
    {
        var catalog = ShellCatalog.Discover(new ShellProbe());
        var transcripts = new TranscriptStore(_directory);
        _manager = new ShellSessionManager(transcripts, catalog.Resolve, start => new ConPty(start), UserEnvironment.Create, UserEnvironment.Home);
        var access = new ShellAccessStore(new MemorySecretStore());
        access.Record(new ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = Key, GrantedAt = DateTimeOffset.UtcNow });
        _gate = new ShellGate(_manager, transcripts, access, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), new ShellGateHooks
        {
            Host = _ => new HostInfo { Kind = "windows", Shells = [.. catalog.Shells] },
        });
        _listener = new IrohShellListener(_host, _gate);
        _listener.Start();
    }

    public void Dispose()
    {
        _listener.Dispose();
        _manager.CloseAll();
        _phone.Dispose();
        _host.Dispose();
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private sealed class Lines(Stream stream)
    {
        private readonly ShellLineReader _reader = new(stream, RemoteShell.LineLimit * 2);
        public Task Send(ShellEnvelope e) => stream.WriteAsync(e.EncodeLine()).AsTask();

        public async Task<ShellEnvelope?> Next()
        {
            try { return await _reader.ReadLineAsync().WaitAsync(Patience) is { } line ? ShellEnvelope.Decode(line) : null; }
            catch (IOException) { return null; }
        }

        public async Task<ShellEnvelope> Next(string type)
        {
            while (true)
            {
                var message = await Next() ?? throw new IOException($"closed before {type}");
                if (message.T == type) return message;
            }
        }
    }

    private async Task<Lines> Dial(byte[] key)
    {
        var stream = await Task.Run(() => _phone.Connect(_host.Id, null, _host.LoopbackAddresses)).WaitAsync(Patience);
        var lines = new Lines(stream);
        await lines.Send(new ShellEnvelope(ShellEnvelope.Hello) { PhoneID = "phone-a" });
        var challenge = await lines.Next(ShellEnvelope.Challenge);
        await lines.Send(new ShellEnvelope(ShellEnvelope.Proof)
        {
            PhoneID = "phone-a",
            Mac = Convert.ToBase64String(RemoteShell.Proof(key, Convert.FromBase64String(challenge.Nonce!))),
        });
        return lines;
    }

    [Fact]
    public async Task APhoneOpensAShellOnThisPcOverIroh()
    {
        var phone = await Dial(Key);
        Assert.Equal(ShellEnvelope.Ready, (await phone.Next())?.T);
        var host = await phone.Next(ShellEnvelope.Host);
        Assert.Contains(host.HostInfo!.Shells!, s => s.Id == "cmd");
        await phone.Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = 80, Rows = 24, Shell = "cmd", Ref = 1 });
        var id = (await phone.Next(ShellEnvelope.Opened)).Session!;
        await phone.Next(ShellEnvelope.Attached);
        await phone.Send(new ShellEnvelope(ShellEnvelope.Input) { Session = id, Data = Convert.ToBase64String("echo over-iroh-%PASSTHROUGH_SESSION%\r"u8) });
        var seen = new StringBuilder();
        while (!seen.ToString().Contains($"over-iroh-{id}", StringComparison.Ordinal))
        {
            var output = await phone.Next(ShellEnvelope.Output);
            seen.Append(Encoding.UTF8.GetString(Convert.FromBase64String(output.Data!)));
        }
        await phone.Send(new ShellEnvelope(ShellEnvelope.Input) { Session = id, Data = Convert.ToBase64String("exit 3\r"u8) });
        Assert.Equal(3, (await phone.Next(ShellEnvelope.Ended)).ExitStatus);
        Assert.Equal(["phone-a"], _gate.ConnectedPhones);
    }

    [Fact]
    public async Task AWrongKeyIsRefusedOverIrohToo()
    {
        var phone = await Dial(new byte[32]);
        Assert.Equal("not_authorized", (await phone.Next())?.Reason);
        Assert.Null(await phone.Next());
        Assert.True(SpinWait.SpinUntil(() => _gate.PendingHandshakes == 0, 5000), "its slot is free again");
    }

    [Fact]
    public void AttemptsAreCountedByIpWhenDirectAndTogetherThroughRelays()
    {
        Assert.Equal(("192.168.1.5", (int?)null), IrohShellListener.Bucket(IrohPath.Direct, "192.168.1.5"));
        Assert.Equal((IrohShellListener.RelayBucket, (int?)IrohShellListener.MaxRelayHandshakes), IrohShellListener.Bucket(IrohPath.Relay, null));
        Assert.Equal((IrohShellListener.RelayBucket, (int?)IrohShellListener.MaxRelayHandshakes), IrohShellListener.Bucket(IrohPath.Direct, null));
    }
}
