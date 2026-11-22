using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Principal;
using System.Text;
using Passthrough.Core.Pipe;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Net;
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
    private readonly string _keyName = "Passthrough.Test.TLS." + Guid.NewGuid().ToString("N");
    private readonly string _certificate;

    public ServiceRemoteTests()
    {
        using (var me = WindowsIdentity.GetCurrent()) _account = me.User!.Value;
        Directory.CreateDirectory(_directory);
        _certificate = Path.Combine(_directory, "tls.cer");
        _remote = new ServiceRemote(_serviceSecrets, AppContext.BaseDirectory, _trays, () => null, _ => { }, "TEST-PC", IrohRelay.None,
            new ServiceRemote.TlsOptions(_certificate, _keyName, Port: 0, Advertise: false));
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
        ServiceIdentity.Forget(_certificate, _keyName);
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    /// <summary>The service's tray links, with one account's tray app on a real pipe.</summary>
    private sealed class Trays : ITrayHosts
    {
        private readonly Dictionary<string, PipeSessionHost> _hosts = [];
        private readonly Dictionary<string, PipeLink> _links = [];
        public Func<string, PipeAdminRequest, PipeAdminReply>? Admin;
        public IReadOnlyList<PipeSessionHost> Hosts { get { lock (_hosts) return [.. _hosts.Values]; } }
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
    public async Task APhoneOnTheSameNetworkConnectsOverTls13WithThePinnedCertificate()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        var grant = (await _admin.GrantContentsAsync())!;
        Assert.Equal(_remote.Pin, grant.CertSHA256);
        Assert.NotEqual(Passthrough.Core.Shell.Access.GrantContents.NoListenerPin, grant.CertSHA256);
        Assert.Equal(_remote.TlsPort, grant.Port);

        using var tcp = new TcpClient();
        await tcp.ConnectAsync("127.0.0.1", grant.Port);
        string? seen = null;
        var ssl = new SslStream(tcp.GetStream(), false, (_, certificate, _, _) =>
        {
            seen = Passthrough.Core.Shell.Identity.CertificateDer.Pin(certificate!.GetRawCertData());
            return seen == grant.CertSHA256; // the phone's rule: the pin, nothing else
        });
        await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "Passthrough PC", EnabledSslProtocols = SslProtocols.Tls13 });
        Assert.Equal(SslProtocols.Tls13, ssl.SslProtocol);
        Assert.Equal(grant.CertSHA256, seen);
        // Over TLS the host speaks first: the challenge, no hello.
        var lines = new Lines(ssl);
        var challenge = await lines.Next(ShellEnvelope.Challenge);
        await lines.Send(new ShellEnvelope(ShellEnvelope.Proof)
        {
            PhoneID = "phone-a",
            Mac = Convert.ToBase64String(RemoteShell.Proof(Key, Convert.FromBase64String(challenge.Nonce!))),
        });
        Assert.Equal(ShellEnvelope.Ready, (await lines.Next())?.T);
    }

    /// <summary>This PC as a viewer (stage 8): its own shell client, against the service, opening a real shell.</summary>
    private async Task ViewerOpensAShell(Passthrough.Core.Client.ShellCredential credential, Passthrough.Core.Client.ShellConnectMode mode)
    {
        var events = System.Threading.Channels.Channel.CreateUnbounded<Passthrough.Core.Client.ShellClientEvent>();
        await using var client = new Passthrough.Core.Client.ShellClient(credential, new Passthrough.Core.Client.PinnedTlsDialer(), new IrohShellDialer(IrohRelay.None),
            e => events.Writer.TryWrite(e), mode);
        client.Connect();
        async Task<T> Next<T>() where T : Passthrough.Core.Client.ShellClientEvent
        {
            while (true)
            {
                var e = await events.Reader.ReadAsync().AsTask().WaitAsync(Patience);
                if (e is Passthrough.Core.Client.ShellClientEvent.Disconnected d) throw new IOException("disconnected", d.Error);
                if (e is T t) return t;
            }
        }
        await Next<Passthrough.Core.Client.ShellClientEvent.Ready>();
        var host = await Next<Passthrough.Core.Client.ShellClientEvent.Host>();
        Assert.Equal("windows", host.Value.Kind);
        client.Open(80, 24, "cmd");
        var session = (await Next<Passthrough.Core.Client.ShellClientEvent.Opened>()).Session;
        await Next<Passthrough.Core.Client.ShellClientEvent.Attached>();
        client.Input("echo viewer-%PASSTHROUGH_SESSION%\r"u8.ToArray());
        var seen = new StringBuilder();
        while (!seen.ToString().Contains($"viewer-{session}", StringComparison.Ordinal))
            seen.Append(Encoding.UTF8.GetString((await Next<Passthrough.Core.Client.ShellClientEvent.Output>()).Data.Span));
    }

    [Fact]
    public async Task ThisPcsShellClientOpensAShellOverPinnedTls()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        var grant = (await _admin.GrantContentsAsync())!;
        await ViewerOpensAShell(new Passthrough.Core.Client.ShellCredential("host", "TEST-PC", grant.CertSHA256, Key, "phone-a", grant.Port, ["127.0.0.1"]),
            Passthrough.Core.Client.ShellConnectMode.LocalOnly);
    }

    [Fact]
    public async Task ThisPcsShellClientOpensAShellOverIroh()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        await ViewerOpensAShell(new Passthrough.Core.Client.ShellCredential("host", "TEST-PC", new string('0', 64), Key, "phone-a", 7893, [.. _remote.LoopbackAddresses],
            IrohId: _remote.IrohId), Passthrough.Core.Client.ShellConnectMode.Automatic);
    }

    [Fact]
    public async Task AWrongPinIsNeverTalkedTo()
    {
        await LinkTrayAsync();
        Assert.True(await _admin.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Key));
        var grant = (await _admin.GrantContentsAsync())!;
        await Assert.ThrowsAsync<IOException>(() => ViewerOpensAShell(
            new Passthrough.Core.Client.ShellCredential("host", "TEST-PC", new string('b', 64), Key, "phone-a", grant.Port, ["127.0.0.1"]),
            Passthrough.Core.Client.ShellConnectMode.LocalOnly));
    }

    [Fact]
    public void ThePinStaysAcrossARestartOfTheService()
    {
        var first = _remote.Pin;
        using var again = ServiceIdentity.LoadOrCreate(_certificate, _keyName);
        Assert.Equal(first, again.Pin);
        // The key can't be taken out.
        Assert.Equal(System.Security.Cryptography.CngExportPolicies.None, again.Key.ExportPolicy);
    }

    [Fact]
    public async Task StayAwakeIsAnyAccountsToSetAndSaysWhatItDoes()
    {
        await LinkTrayAsync();
        Assert.False((await _admin.PowerAsync()).StayAwake);
        Assert.Null((await _admin.SetStayAwakeAsync(true)).Error);
        var power = await _admin.PowerAsync();
        Assert.True(power.StayAwake);
        if (power.OnMains == true) Assert.Equal(0, power.SleepAfter);
        Assert.Equal("true", _serviceSecrets.Get(ServiceRemote.StayAwakeSlot));
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
