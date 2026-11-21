using System.Security.Principal;
using System.Text;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Pipes;
using Passthrough.Windows.Remote;
using Passthrough.Windows.Shell;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>
/// Stage 4 end to end, in one process: a phone over iroh to the service's gate, which reaches this account's tray app
/// over a real named pipe, which runs a real shell in ConPTY. Everything but the Service Control Manager.
/// </summary>
public sealed class ServiceRemoteTests : IDisposable
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);
    private static readonly byte[] Key = Enumerable.Repeat((byte)5, 32).ToArray();
    private readonly string _account;
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"ServiceRemoteTests-{Guid.NewGuid():N}");
    private readonly MemorySecretStore _serviceSecrets = new();
    private readonly Trays _trays = new();
    private readonly ServiceRemote _remote;
    private readonly ShellSessionManager _manager;
    private readonly PipeSessionServer _tray;
    private readonly PipeAccessAdmin _admin;
    private readonly IrohEndpoint _phone = IrohEndpoint.Bind([], IrohRelay.None);
    private PipeLink? _trayLink;

    public ServiceRemoteTests()
    {
        using (var me = WindowsIdentity.GetCurrent()) _account = me.User!.Value;
        _remote = new ServiceRemote(_serviceSecrets, AppContext.BaseDirectory, _trays, () => null, _ => { }, "TEST-PC", IrohRelay.None);
        _trays.Admin = _remote.Admin.Handle;
        _remote.Start();
        var catalog = ShellCatalog.Discover(new ShellProbe());
        var transcripts = new TranscriptStore(_directory);
        _manager = new ShellSessionManager(transcripts, catalog.Resolve, start => new ConPty(start), UserEnvironment.Create, UserEnvironment.Home);
        _tray = new PipeSessionServer(new LocalSessionHost(_manager, transcripts), () => new PipeHostState { Shells = [.. catalog.Shells], User = "dev" }, () => null);
        _admin = new PipeAccessAdmin(_tray);
    }

    public void Dispose()
    {
        _trayLink?.Close();
        _remote.Dispose();
        _manager.CloseAll();
        _phone.Dispose();
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    /// <summary>The service's tray links, with one account's tray app on a real pipe.</summary>
    private sealed class Trays : ITrayHosts
    {
        private readonly Dictionary<string, PipeSessionHost> _hosts = [];
        private readonly Dictionary<string, PipeLink> _links = [];
        public Func<string, PipeAdminRequest, PipeAdminReply>? Admin;
        public event Action<PipeSessionHost>? Changed;

        public PipeSessionHost HostFor(string account)
        {
            lock (_hosts)
            {
                if (_hosts.TryGetValue(account, out var host)) return host;
                host = new PipeSessionHost(account);
                host.Changed += () => Changed?.Invoke(host);
                host.StateChanged += () => Changed?.Invoke(host);
                return _hosts[account] = host;
            }
        }

        public void Tell(string account, PipeAdminEvent e)
        {
            lock (_hosts) if (_links.TryGetValue(account, out var link)) link.Send(PipeFrame.Json(PipeKind.AdminEvent, e));
        }

        public void TellAll(PipeAdminEvent e)
        {
            lock (_hosts) foreach (var link in _links.Values) link.Send(PipeFrame.Json(PipeKind.AdminEvent, e));
        }

        public void Link(string account, PipeLink link)
        {
            var host = HostFor(account);
            lock (_hosts) _links[account] = link;
            host.Link(link);
            _ = Task.Run(async () =>
            {
                await link.RunAsync(frame =>
                {
                    if (frame.Kind != PipeKind.Admin) return host.OnFrameAsync(frame);
                    if (frame.Read<PipeAdminRequest>() is { } request) link.Send(PipeFrame.Json(PipeKind.AdminReply, Admin!(account, request)));
                    return ValueTask.CompletedTask;
                });
                host.Unlink(link);
            });
        }
    }

    /// <summary>The tray app connects to the service's pipe (a real one, this account standing in for the service's SID).</summary>
    private async Task LinkTrayAsync()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        var server = ServicePipe.CreateInstance(first: true, name, serviceSid: _account);
        var accepted = server.WaitForConnectionAsync();
        var client = ServicePipe.Connect(name, serviceSid: _account, servicePid: () => Environment.ProcessId);
        await accepted;
        Assert.Equal(_account, ServicePipe.Peer(server)!.Account);
        _trays.Link(_account, new PipeLink(server, service: true, 4 << 20));
        _trayLink = new PipeLink(client, service: false, PipeSessionServer.LinkBacklogLimit);
        _ = Task.Run(() => _tray.ServeAsync(_trayLink));
        var deadline = DateTime.UtcNow + Patience;
        while (!_trays.HostFor(_account).IsAvailable || !_tray.IsLinked) { await Task.Delay(10); Assert.True(DateTime.UtcNow < deadline); }
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
        var stream = await Task.Run(() => _phone.Connect(_remote.IrohId!, null, _remote.LoopbackAddresses)).WaitAsync(Patience);
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
    public async Task APhoneOpensAShellThroughTheServiceAndTheTrayApp()
    {
        await LinkTrayAsync();
        // The cable grant's key reaches the service through the pipe, for this account.
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        Assert.Equal(_account, _remote.Directory.Owner("phone-a"));
        var grant = await _admin.GrantContentsAsync();
        Assert.Equal(_remote.IrohId, grant!.IrohId);
        Assert.Equal("TEST-PC", grant.HostName);

        var phone = await Dial(Key);
        Assert.Equal(ShellEnvelope.Ready, (await phone.Next())?.T);
        var host = await phone.Next(ShellEnvelope.Host);
        Assert.True(host.HostInfo!.App);
        Assert.Contains(host.HostInfo.Shells!, s => s.Id == "cmd");
        await phone.Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = 80, Rows = 24, Shell = "cmd", Ref = 1 });
        var id = (await phone.Next(ShellEnvelope.Opened)).Session!;
        await phone.Next(ShellEnvelope.Attached);
        await phone.Send(new ShellEnvelope(ShellEnvelope.Input) { Session = id, Data = Convert.ToBase64String("echo via-service-%PASSTHROUGH_SESSION%\r"u8) });
        var seen = new StringBuilder();
        while (!seen.ToString().Contains($"via-service-{id}", StringComparison.Ordinal))
            seen.Append(Encoding.UTF8.GetString(Convert.FromBase64String((await phone.Next(ShellEnvelope.Output)).Data!)));

        // The tray app goes: the phone is told, and its shell keeps running for when it comes back.
        _trayLink!.Close();
        Assert.Equal(id, (await phone.Next(ShellEnvelope.Detached)).Session);
        await phone.Send(new ShellEnvelope(ShellEnvelope.Open) { Cols = 80, Rows = 24, Ref = 2 });
        Assert.Equal("signed_out", (await phone.Next(ShellEnvelope.Error)).Reason);
        Assert.True(_manager.Sessions.Single().Running);
    }

    [Fact]
    public async Task RevokingThroughThePipeEndsThePhonesConnection()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        var phone = await Dial(Key);
        await phone.Next(ShellEnvelope.Sessions);
        Assert.Null((await _admin.RevokeAsync("phone-a")).Error);
        while (await phone.Next() is not null) { }
        Assert.Empty(await _admin.ListAsync());
        var again = await Dial(Key);
        Assert.Equal("not_authorized", (await again.Next())?.Reason);
    }

    [Fact]
    public async Task AnotherAccountCantClaimAPhoneOrSeeIt()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        var other = _remote.Admin.Handle("S-1-5-21-9-9-9-1002", new PipeAdminRequest { Op = PipeAdminRequest.AddKey, Phone = "phone-a", PairingSlot = "token.iphone.B", Key = Convert.ToBase64String(new byte[32]) });
        Assert.Equal(PipeAdminReply.NotYours, other.Error);
        Assert.Empty(_remote.Admin.Handle("S-1-5-21-9-9-9-1002", new PipeAdminRequest { Op = PipeAdminRequest.List }).Devices!);
        Assert.Equal(PipeAdminReply.Unknown, _remote.Admin.Handle("S-1-5-21-9-9-9-1002", new PipeAdminRequest { Op = PipeAdminRequest.Revoke, Phone = "phone-a" }).Error);
        Assert.Single(await _admin.ListAsync());
    }

    [Fact]
    public async Task TheServiceMakesItsOwnIdentityAndKeepsIt()
    {
        var stored = _serviceSecrets.Get(ServiceRemote.IrohKeySlot);
        Assert.NotNull(stored);
        Assert.Equal(IrohEndpoint.IdOf(Convert.FromBase64String(stored!)), _remote.IrohId);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task StageThreeRecordsAreHandedOverOnce()
    {
        await LinkTrayAsync();
        var record = new Passthrough.Core.Shell.Access.ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = Key, GrantedAt = DateTimeOffset.UtcNow };
        var first = await _admin.HandOverAsync([record]);
        Assert.Equal(["phone-a"], first.Taken);
        var again = await _admin.HandOverAsync([record]);
        Assert.Equal(["phone-a"], again.Kept);
        Assert.Equal(["phone-a"], _remote.Admin.Handle("S-1-5-21-9-9-9-1002", new PipeAdminRequest { Op = PipeAdminRequest.HandOver, Records = [record] }).Refused);
    }
}
