using System.Net;
using System.Threading.Channels;
using Passthrough.Core.Client;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Serving;
using Passthrough.Core.Tests.Pipe;
using Xunit;

namespace Passthrough.Core.Tests.Client;

/// <summary>The screen hand-over (ShellClient.swift:563-587, :791-808): lines up to screenVideoReady, then the rest of the stream as it is.</summary>
public sealed class ShellClientScreenTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    private sealed class OneStream(Stream stream) : IPinnedTlsDialer, IShellStream
    {
        public bool Disposed;
        public Stream Stream => stream;
        public IPAddress? LocalAddress => IPAddress.Loopback;
        public Task<IShellStream> ConnectAsync(ShellEndpoint endpoint, string certSha256, CancellationToken cancel) => Task.FromResult<IShellStream>(this);
        public ValueTask DisposeAsync() { Disposed = true; stream.Dispose(); return ValueTask.CompletedTask; }
    }

    /// <summary>A client let in by a host played here, over an in-memory stream.</summary>
    private static async Task<(ShellClient Client, Channel<ShellClientEvent> Events, ShellLineReader HostLines, Stream Host, OneStream Link)> ReadyAsync()
    {
        var (host, viewer) = DuplexStreams.Create();
        var link = new OneStream(viewer);
        var events = Channel.CreateUnbounded<ShellClientEvent>();
        var credential = new ShellCredential("host", "MacBook", new string('a', 64), new byte[32], "viewer-1", 7000, ["127.0.0.1"]);
        var client = new ShellClient(credential, link, null, e => events.Writer.TryWrite(e), ShellConnectMode.LocalOnly);
        client.Connect();
        var lines = new ShellLineReader(host, RemoteShell.LineLimit);
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Challenge) { Nonce = Convert.ToBase64String(new byte[32]) }.EncodeLine());
        Assert.Equal(ShellEnvelope.Proof, ShellEnvelope.Decode((await lines.ReadLineAsync().WaitAsync(Wait))!).T);
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Ready).EncodeLine());
        Assert.IsType<ShellClientEvent.Ready>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
        return (client, events, lines, host, link);
    }

    [Fact]
    public async Task ScreenVideoReadyHandsOverTheStreamWithTheBytesAfterIt()
    {
        var (client, events, lines, host, link) = await ReadyAsync();
        client.RequestScreen(video: true);
        Assert.Equal(ShellEnvelope.ScreenVideo, ShellEnvelope.Decode((await lines.ReadLineAsync().WaitAsync(Wait))!).T);
        // The answer and the stream's first bytes in one write, as a host may send them.
        byte[] first = [5, 0, 0, 0, 1, 0, (byte)'\n', 9];
        await host.WriteAsync((byte[])[.. new ShellEnvelope(ShellEnvelope.ScreenVideoReady).EncodeLine(), .. first]);
        var screen = Assert.IsType<ShellClientEvent.Screen>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
        Assert.Equal(first, screen.InitialBytes.ToArray());
        Assert.Same(link, screen.Stream);
        Assert.False(link.Disposed, "the stream is the receiver's now");
        // Nothing more from the client: no Disconnected, and what it is asked to send doesn't reach the stream.
        client.List();
        await Task.Delay(200);
        Assert.False(events.Reader.TryRead(out _));
        await screen.Stream.Stream.WriteAsync(new byte[] { 42 });
        var buffer = new byte[16];
        var n = await host.ReadAsync(buffer).AsTask().WaitAsync(Wait);
        Assert.Equal([42], buffer[..n]);
        Assert.False(lines.HasBuffered);
        await client.DisposeAsync();
        Assert.False(link.Disposed);
    }

    [Fact]
    public async Task ARefusalLeavesTheConnectionUsable()
    {
        var (client, events, lines, host, _) = await ReadyAsync();
        client.RequestScreen(video: true);
        await lines.ReadLineAsync().WaitAsync(Wait);
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Error) { Reason = "screen_video_unavailable" }.EncodeLine());
        Assert.IsType<ShellClientEvent.Failed>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
        client.List();
        Assert.Equal(ShellEnvelope.List, ShellEnvelope.Decode((await lines.ReadLineAsync().WaitAsync(Wait))!).T);
        await client.DisposeAsync();
        Assert.IsType<ShellClientEvent.Disconnected>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
    }

    [Fact]
    public async Task ClipSyncReadyHandsOverTheStreamWithTheBytesAfterIt()
    {
        var (client, events, lines, host, link) = await ReadyAsync();
        client.RequestClipSync();
        Assert.Equal(ShellEnvelope.ClipSync, ShellEnvelope.Decode((await lines.ReadLineAsync().WaitAsync(Wait))!).T);
        // The answer and the host's hello in one write.
        byte[] hello = [1, 0, 0, 0, 2, 1, 0];
        await host.WriteAsync((byte[])[.. new ShellEnvelope(ShellEnvelope.ClipSyncReady).EncodeLine(), .. hello]);
        var sync = Assert.IsType<ShellClientEvent.ClipSync>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
        Assert.Equal(hello, sync.InitialBytes.ToArray());
        Assert.Same(link, sync.Stream);
        Assert.False(link.Disposed, "the stream is the receiver's now");
        client.List();
        await Task.Delay(200);
        Assert.False(events.Reader.TryRead(out _));
        await client.DisposeAsync();
        Assert.False(link.Disposed);
    }

    [Fact]
    public async Task AClipSyncRefusalSaysWhy_AndLeavesTheConnectionUsable()
    {
        var (client, events, lines, host, _) = await ReadyAsync();
        foreach (var (wire, reason) in new[] { ("no_screen_view", ShellError.NoScreenView), ("clip_sync_off", ShellError.ClipSyncOff), ("clip_sync_unavailable", ShellError.ClipSyncUnavailable) })
        {
            client.RequestClipSync();
            await lines.ReadLineAsync().WaitAsync(Wait);
            await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Error) { Reason = wire }.EncodeLine());
            Assert.Equal(reason, Assert.IsType<ShellClientEvent.ClipSyncRefused>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait)).Reason);
        }
        // An older host knows no clipSync: its bad_request is a refusal too.
        client.RequestClipSync();
        await lines.ReadLineAsync().WaitAsync(Wait);
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Error) { Reason = "bad_request" }.EncodeLine());
        Assert.Equal(ShellError.BadRequest, Assert.IsType<ShellClientEvent.ClipSyncRefused>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait)).Reason);
        client.List();
        Assert.Equal(ShellEnvelope.List, ShellEnvelope.Decode((await lines.ReadLineAsync().WaitAsync(Wait))!).T);
        await client.DisposeAsync();
    }

    [Fact]
    public async Task AScreenAnsweredToClipSync_EndsTheConnection_NothingIsHandedOver()
    {
        var (client, events, lines, host, link) = await ReadyAsync();
        client.RequestClipSync();
        await lines.ReadLineAsync().WaitAsync(Wait);
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.ScreenVideoReady).EncodeLine());
        Assert.NotNull(Assert.IsType<ShellClientEvent.Disconnected>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait)).Error);
        Assert.True(link.Disposed);
        await client.DisposeAsync();
    }

    [Fact]
    public async Task AScreenReadyNobodyAskedForIsJustALine()
    {
        var (client, events, _, host, _) = await ReadyAsync();
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.ScreenVideoReady).EncodeLine());
        await host.WriteAsync(new ShellEnvelope(ShellEnvelope.Sessions) { SessionList = [] }.EncodeLine());
        Assert.IsType<ShellClientEvent.Sessions>(await events.Reader.ReadAsync().AsTask().WaitAsync(Wait));
        await client.DisposeAsync();
    }
}
