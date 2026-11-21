using System.Text;
using Passthrough.Windows.Iroh;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>
/// The iroh bridge over loopback, relays off: a host endpoint with a stable id and a viewer's ephemeral one dialling it,
/// as IrohTransportTests do on the Mac.
/// </summary>
public sealed class IrohTests : IDisposable
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(30);
    private readonly List<IDisposable> _owned = [];

    public IrohTests()
    {
        Assert.True(IrohNative.IsAvailable, "build the bridge first: windows/native/build-iroh-bridge.ps1");
    }

    public void Dispose()
    {
        for (var i = _owned.Count - 1; i >= 0; i--) _owned[i].Dispose();
    }

    private T Own<T>(T item) where T : IDisposable { _owned.Add(item); return item; }

    private (IrohEndpoint Host, IrohEndpoint Viewer) Pair()
    {
        var host = Own(IrohEndpoint.Bind(IrohEndpoint.NewSecretKey(), IrohRelay.None, IrohEndpoint.ShellAlpn));
        var viewer = Own(IrohEndpoint.Bind([], IrohRelay.None));
        return (host, viewer);
    }

    private static async Task<byte[]> ReadToEnd(Stream stream)
    {
        using var all = new MemoryStream();
        await stream.CopyToAsync(all).WaitAsync(Patience);
        return all.ToArray();
    }

    [Fact]
    public void ASecretKeyGivesAStableId()
    {
        var key = IrohEndpoint.NewSecretKey();
        Assert.Equal(32, key.Length);
        using var first = IrohEndpoint.Bind(key, IrohRelay.None, IrohEndpoint.ShellAlpn);
        var id = first.Id;
        first.Dispose();
        using var again = IrohEndpoint.Bind(key, IrohRelay.None, IrohEndpoint.ShellAlpn);
        Assert.Equal(id, again.Id);
        Assert.Equal(id, IrohEndpoint.IdOf(key));
        Assert.NotEqual(id, IrohEndpoint.IdOf(IrohEndpoint.NewSecretKey()));
        Assert.NotEmpty(again.LoopbackAddresses);
        Assert.Throws<ArgumentException>(() => IrohEndpoint.Bind(new byte[16], IrohRelay.None));
    }

    [Fact]
    public async Task AViewerDialsTheHostAndBothSidesTalk()
    {
        var (host, viewer) = Pair();
        var accepted = Task.Run(() =>
        {
            using var attempt = host.Accept()!;
            Assert.Equal(IrohPath.Direct, attempt.Origin().Path);
            Assert.Equal("127.0.0.1", attempt.Origin().Ip);
            return attempt.AcceptStream();
        });
        using var dialled = viewer.Connect(host.Id, null, host.LoopbackAddresses.Where(a => a.StartsWith("127.", StringComparison.Ordinal)));
        // The host sees the stream once the viewer writes to it.
        await dialled.WriteAsync("hello\n"u8.ToArray());
        using var served = Own(await accepted.WaitAsync(Patience));
        var buffer = new byte[6];
        await served.ReadExactlyAsync(buffer).AsTask().WaitAsync(Patience);
        Assert.Equal("hello\n", Encoding.UTF8.GetString(buffer));
        Assert.Equal(viewer.Id, served.RemoteId);
        Assert.Equal(host.Id, dialled.RemoteId);
        Assert.Equal(IrohPath.Direct, served.CurrentPath.Path);

        // A large write arrives whole and in order, and waits on a reader that falls behind (back-pressure), as over TCP.
        var big = Enumerable.Range(0, 3 << 20).Select(i => (byte)i).ToArray();
        var reading = ReadToEnd(dialled);
        await served.WriteAsync(big).AsTask().WaitAsync(Patience);
        await served.FinishAsync().WaitAsync(Patience);
        Assert.Equal(big, await reading);
    }

    [Fact]
    public async Task WhatIsWrittenBeforeClosingArrives_AndTheCloseIsClean()
    {
        var (host, viewer) = Pair();
        var accepted = Task.Run(() => { using var a = host.Accept()!; return a.AcceptStream(); });
        var dialled = viewer.Connect(host.Id, null, host.LoopbackAddresses);
        await dialled.WriteAsync("last words"u8.ToArray());
        var served = Own(await accepted.WaitAsync(Patience));
        dialled.Dispose();
        Assert.Equal("last words", Encoding.UTF8.GetString(await ReadToEnd(served)));
        Assert.Equal(IrohClose.Clean, (await served.Closed.WaitAsync(Patience)).Kind);
    }

    [Fact]
    public async Task ARetryValidatesThePeersAddress()
    {
        var (host, viewer) = Pair();
        var accepted = Task.Run(() =>
        {
            using (var first = host.Accept()!)
            {
                Assert.False(first.IsAddressValidated);
                Assert.True(first.Retry());
            }
            using var second = host.Accept()!;
            Assert.True(second.IsAddressValidated);
            Assert.False(second.Retry(), "a peer that came with a token can't be asked again");
            return true;
        });
        var dial = Task.Run(() => viewer.Connect(host.Id, null, host.LoopbackAddresses));
        Assert.True(await accepted.WaitAsync(Patience));
        // The second attempt was turned away by the failed retry: the dial fails rather than hangs.
        await Assert.ThrowsAsync<IrohException>(() => dial.WaitAsync(Patience));
    }

    [Fact]
    public async Task ACancelledAttemptFailsTheDial_AndClosingTheEndpointEndsItsAccept()
    {
        var (host, viewer) = Pair();
        var turnedAway = Task.Run(() => { using var a = host.Accept()!; a.Cancel(); });
        await Assert.ThrowsAsync<IrohException>(() => Task.Run(() => viewer.Connect(host.Id, null, host.LoopbackAddresses)).WaitAsync(Patience));
        await turnedAway.WaitAsync(Patience);

        var waiting = Task.Run(() => host.Accept());
        await Task.Delay(200);
        host.Close();
        Assert.Null(await waiting.WaitAsync(Patience));
    }

    [Fact]
    public async Task AnotherProtocolIsRefused()
    {
        var (host, viewer) = Pair();
        _ = Task.Run(() => { try { using var a = host.Accept(); a?.AcceptStream().Dispose(); } catch (IrohException) { } });
        var error = await Assert.ThrowsAsync<IrohException>(() => Task.Run(() => viewer.Connect(host.Id, null, host.LoopbackAddresses, "passthrough/other/1")).WaitAsync(Patience));
        Assert.Equal(IrohNative.ErrConnection, error.Code);
    }

    [Fact]
    public void BadHandlesAndArgumentsAreErrorsNotCrashes()
    {
        Assert.Equal(IrohNative.ErrBadHandle, IrohNative.pt_iroh_free(987_654_321));
        Assert.Equal(IrohNative.ErrBadHandle, IrohNative.pt_iroh_stream_close(1));
        Assert.Contains("no such handle", IrohNative.Failure(IrohNative.pt_iroh_free(987_654_321)).Message);
        var (_, viewer) = Pair();
        var error = Assert.Throws<IrohException>(() => viewer.Connect("not an id", null, []));
        Assert.Equal(IrohNative.ErrArgument, error.Code);
        Assert.Throws<IrohException>(() => viewer.Connect(IrohEndpoint.IdOf(IrohEndpoint.NewSecretKey()), "not a url", []));
        Assert.Throws<IrohException>(() => IrohEndpoint.Bind([], new IrohRelay("::not a url::")));
    }
}
