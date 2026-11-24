using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using Passthrough.Core.ClipSync;
using Passthrough.Core.Screen;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Shell.Sessions;
using Passthrough.Core.Storage;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Tests.Pipe;
using Passthrough.Core.Tests.Shell;
using Xunit;

namespace Passthrough.Core.Tests.ClipSync;

/// <summary>
/// <c>clipSync</c> at a PC host's gate (protocol/README.md, "Clipboard sync"): who may ask, only while that device
/// views the screen, one per device, and gone within a second of its last view.
/// </summary>
public sealed class ClipSyncGateTests : IAsyncDisposable
{
    private const string Account = "S-1-5-21-1-2-3-1001";
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(10);
    private static readonly byte[] PhoneKey = Enumerable.Repeat((byte)9, 32).ToArray();
    private static readonly ProofBinding Binding = new(ComputerProof.PathTls, Enumerable.Repeat((byte)0xAB, 32).ToArray());
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"ClipSyncGateTests-{Guid.NewGuid():N}");
    private readonly AccessDirectory _access = new(new MemorySecretStore());
    private readonly ShellSessionManager _manager;
    private readonly ShellGate _gate;
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly ECDsa _identity = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly Desktop _desktop = new();
    /// <summary>What the tray app would be: each sync's far end, and what the gate may be told instead of a stream.</summary>
    private readonly List<Stream> _trayEnds = [];
    private ShellError? _refuse;
    private int _asked;

    public ClipSyncGateTests()
    {
        var transcripts = new TranscriptStore(_directory);
        _manager = new ShellSessionManager(transcripts, _ => new ShellCommand("cmd", @"C:\cmd.exe", []), start => new FakePty(start),
            () => new Dictionary<string, string>(), @"C:\Users\dev");
        _access.Add(Account, new ShellPhone { PhoneId = "phone-a", Label = "iPhone", PairingSlot = "token.iphone.A", Key = PhoneKey, GrantedAt = DateTimeOffset.UtcNow });
        _access.For(Account).SetShareAllowed("phone-a", true);
        _access.For(Account).SetScreenAllowed("phone-a", true);
        var host = new LocalSessionHost(_manager, transcripts);
        _gate = new ShellGate(_ => host, _access, new HandshakeLimiter(TimeSpan.FromSeconds(10), TimeProvider.System), new ShellGateHooks
        {
            Host = _ => new HostInfo { Kind = "windows", Shells = [] },
            State = _ => new HostState { Control = false },
            RemoteDesktop = _desktop,
            AccountOf = _ => Account,
            ClipSync = (_, _, _) =>
            {
                Interlocked.Increment(ref _asked);
                if (_refuse is { } refusal) return Task.FromResult<(Stream?, ShellError?)>((null, refusal));
                var (gateEnd, trayEnd) = DuplexStreams.Create();
                lock (_trayEnds) _trayEnds.Add(trayEnd);
                return Task.FromResult<(Stream?, ShellError?)>((gateEnd, null));
            },
        });
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

    /// <summary>Remote Desktop behind the relay: answers the first request as Network Level Authentication, then echoes.</summary>
    private sealed class Desktop : IRemoteDesktopGate
    {
        public Task<RelayVerdict> CheckAsync(string? account, CancellationToken cancel) => Task.FromResult(RelayVerdict.Ready(3389));

        public Task<Stream?> DialAsync(int port, CancellationToken cancel)
        {
            var (ours, theirs) = DuplexStreams.Create();
            _ = Task.Run(async () =>
            {
                var request = new byte[19];
                await theirs.ReadExactlyAsync(request);
                await theirs.WriteAsync(global::Passthrough.Core.Tests.Screen.ScreenTests.Confirm(2));
                var buffer = new byte[4096];
                int n;
                try { while ((n = await theirs.ReadAsync(buffer)) > 0) await theirs.WriteAsync(buffer.AsMemory(0, n)); }
                catch (Exception e) when (e is IOException or ObjectDisposedException) { }
            });
            return Task.FromResult<Stream?>(ours);
        }

        public Task<string?> CertificateSha256Async(CancellationToken cancel) => Task.FromResult<string?>(new string('a', 64));
    }

    private sealed class Line(TcpClient client) : IDisposable
    {
        private readonly ShellLineReader _reader = new(client.GetStream(), RemoteShell.LineLimit * 2);
        public NetworkStream Raw => client.GetStream();
        public Task Send(ShellEnvelope e) => client.GetStream().WriteAsync(e.EncodeLine()).AsTask();

        public async Task<ShellEnvelope> Next(params string[] types)
        {
            while (true)
            {
                var line = await _reader.ReadLineAsync().WaitAsync(Patience) ?? throw new IOException("closed");
                var message = ShellEnvelope.Decode(line);
                if (types.Contains(message.T) || message.T == ShellEnvelope.Error) return message;
            }
        }

        /// <summary>True once the host has closed this connection.</summary>
        public async Task<bool> ClosedWithin(TimeSpan limit)
        {
            var buffer = new byte[256];
            try
            {
                using var cancel = new CancellationTokenSource(limit);
                while (await client.GetStream().ReadAsync(buffer, cancel.Token) > 0) { }
                return true;
            }
            catch (OperationCanceledException) { return false; }
            catch (IOException) { return true; }
        }

        public void Dispose() => client.Dispose();
    }

    private async Task<Line> Connect(string id, byte[] key)
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
            Sig = Computers.IsComputerId(id)
                ? Convert.ToBase64String(_identity.SignData(ComputerProof.Message(nonce, Binding.Path, Binding.HostBinding, id), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
                : null,
        });
        Assert.Equal(ShellEnvelope.Ready, (await line.Next(ShellEnvelope.Ready)).T);
        return line;
    }

    /// <summary>A Mac a phone let in, with or without the screen.</summary>
    private ShellComputer Computer(bool screen = true)
    {
        var q = _identity.ExportParameters(false).Q;
        var (computer, error) = _access.GrantComputer("phone-a", "MacBook", "mac-1", "mac", [0x04, .. q.X!, .. q.Y!],
            screen ? new HashSet<string> { "shell", "screen" } : new HashSet<string> { "shell" }, screenNeedsOwner: false);
        Assert.Null(error);
        return computer!;
    }

    /// <summary>A connection of <paramref name="c"/>'s that is viewing the screen now (past <c>rdpReady</c> and the first exchange).</summary>
    private async Task<Line> View(ShellComputer c)
    {
        var view = await Connect(c.Id, c.Key);
        await view.Send(new ShellEnvelope(ShellEnvelope.Rdp));
        Assert.Equal(ShellEnvelope.RdpReady, (await view.Next(ShellEnvelope.RdpReady)).T);
        await view.Raw.WriteAsync(global::Passthrough.Core.Tests.Screen.ScreenTests.Request(0x0B));
        await view.Raw.ReadExactlyAsync(new byte[19]).AsTask().WaitAsync(Patience);
        Assert.True(_gate.IsViewing(c.Id));
        return view;
    }

    private async Task<ShellEnvelope> Ask(Line line)
    {
        await line.Send(new ShellEnvelope(ShellEnvelope.ClipSync));
        return await line.Next(ShellEnvelope.ClipSyncReady);
    }

    [Fact]
    public async Task AComputerViewingTheScreen_GetsClipSyncReady_ThenItsBytesReachTheTrayAppAndBack()
    {
        var c = Computer();
        using var view = await View(c);
        using var clip = await Connect(c.Id, c.Key);
        Assert.Equal(ShellEnvelope.ClipSyncReady, (await Ask(clip)).T);
        Stream tray;
        lock (_trayEnds) tray = Assert.Single(_trayEnds);
        // Past the answer the connection is clipboard sync's messages, as they are, both ways.
        var hello = ClipSyncWire.Encode(new ClipMessage.Hello(1));
        await clip.Raw.WriteAsync(hello);
        var got = new byte[hello.Length];
        await tray.ReadExactlyAsync(got).AsTask().WaitAsync(Patience);
        Assert.Equal(hello, got);
        var offer = ClipSyncWire.Encode(new ClipMessage.Offer(new ClipOffer(1, ClipKind.Clipboard, 0, 0, 1, 3)));
        await tray.WriteAsync(offer);
        got = new byte[offer.Length];
        await clip.Raw.ReadExactlyAsync(got).AsTask().WaitAsync(Patience);
        Assert.Equal(offer, got);
        Assert.True(_gate.IsSyncingClipboard(c.Id));
        // The sync's connection is not a view of the screen.
        view.Dispose();
        Assert.True(await clip.ClosedWithin(TimeSpan.FromSeconds(3)), "sync ends within a second of the last view");
        Assert.False(_gate.IsSyncingClipboard(c.Id));
        // And the tray app's end hears it.
        try { Assert.Equal(0, await tray.ReadAsync(new byte[1]).AsTask().WaitAsync(Patience)); }
        catch (ObjectDisposedException) { } // these in-memory streams end both ends at once
    }

    [Fact]
    public async Task WithoutAView_ItIsNoScreenView_AndTheConnectionStaysAShellConnection()
    {
        var c = Computer();
        using var clip = await Connect(c.Id, c.Key);
        Assert.Equal("no_screen_view", (await Ask(clip)).Reason);
        Assert.Equal(0, _asked);
        await clip.Send(new ShellEnvelope(ShellEnvelope.List));
        Assert.Equal(ShellEnvelope.Sessions, (await clip.Next(ShellEnvelope.Sessions)).T);
    }

    [Fact]
    public async Task APhone_IsNotAllowed_AndAComputerWithoutTheScreen_IsScreenNotAllowed()
    {
        using var phone = await Connect("phone-a", PhoneKey);
        Assert.Equal("not_allowed", (await Ask(phone)).Reason);
        var c = Computer(screen: false);
        using var computer = await Connect(c.Id, c.Key);
        Assert.Equal("screen_not_allowed", (await Ask(computer)).Reason);
        Assert.Equal(0, _asked);
    }

    [Fact]
    public async Task WhatTheTrayAppAnswers_IsWhatTheViewerIsTold()
    {
        var c = Computer();
        using var view = await View(c);
        using var clip = await Connect(c.Id, c.Key);
        _refuse = ShellError.ClipSyncOff;
        Assert.Equal("clip_sync_off", (await Ask(clip)).Reason);
        _refuse = ShellError.ClipSyncUnavailable;
        Assert.Equal("clip_sync_unavailable", (await Ask(clip)).Reason);
        // Still a shell connection, and asked again it is given.
        _refuse = null;
        Assert.Equal(ShellEnvelope.ClipSyncReady, (await Ask(clip)).T);
    }

    [Fact]
    public async Task ANewSync_ReplacesTheOld_WhichCloses()
    {
        var c = Computer();
        using var view = await View(c);
        using var first = await Connect(c.Id, c.Key);
        Assert.Equal(ShellEnvelope.ClipSyncReady, (await Ask(first)).T);
        using var second = await Connect(c.Id, c.Key);
        Assert.Equal(ShellEnvelope.ClipSyncReady, (await Ask(second)).T);
        Assert.True(await first.ClosedWithin(TimeSpan.FromSeconds(3)));
        Assert.False(await second.ClosedWithin(TimeSpan.FromMilliseconds(1200)), "the new one stays while the view does");
    }

    [Fact]
    public async Task StoppingTheView_OrTurningScreenOff_EndsTheSyncToo()
    {
        var c = Computer();
        using var view = await View(c);
        using var clip = await Connect(c.Id, c.Key);
        Assert.Equal(ShellEnvelope.ClipSyncReady, (await Ask(clip)).T);
        _gate.DisconnectScreen(c.Id, "stopped");
        Assert.True(await clip.ClosedWithin(TimeSpan.FromSeconds(3)));
        Assert.True(await view.ClosedWithin(TimeSpan.FromSeconds(3)));
    }

    [Fact]
    public async Task SomethingSentBeforeTheAnswer_ClosesTheConnection()
    {
        var c = Computer();
        using var view = await View(c);
        using var clip = await Connect(c.Id, c.Key);
        // The request and clipboard sync's first bytes in one write: it didn't wait to be let in.
        await clip.Raw.WriteAsync((byte[])[.. new ShellEnvelope(ShellEnvelope.ClipSync).EncodeLine(), .. ClipSyncWire.Encode(new ClipMessage.Hello(1))]);
        Assert.True(await clip.ClosedWithin(TimeSpan.FromSeconds(3)));
        Assert.False(_gate.IsSyncingClipboard(c.Id));
    }
}
