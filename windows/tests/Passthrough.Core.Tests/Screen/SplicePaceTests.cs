using Passthrough.Core.Screen;
using Xunit;

namespace Passthrough.Core.Tests.Screen;

/// <summary>What goes to a viewer over a relay waits while the relay's queue is long, and never for long.</summary>
public class SplicePaceTests
{
    [Fact]
    public async Task ADirectPathOrAShortRoundTripIsNeverHeld()
    {
        Assert.Equal(TimeSpan.Zero, await Splice.PaceAsync(() => null, TimeProvider.System, default));
        Assert.Equal(TimeSpan.Zero, await Splice.PaceAsync(() => Splice.PaceAbove, TimeProvider.System, default));
    }

    [Fact]
    public async Task ALongRoundTripHoldsUntilItFalls()
    {
        var asked = 0;
        var held = await Splice.PaceAsync(() => ++asked < 4 ? TimeSpan.FromSeconds(5) : TimeSpan.FromMilliseconds(100), TimeProvider.System, default);
        Assert.Equal(4, asked);
        Assert.InRange(held, TimeSpan.FromMilliseconds(100), Splice.PaceLimit);
    }

    [Fact]
    public async Task APathThatStaysSlowIsHeldOnlySoLong()
    {
        var held = await Splice.PaceAsync(() => TimeSpan.FromSeconds(20), TimeProvider.System, default);
        Assert.InRange(held, Splice.PaceLimit, Splice.PaceLimit + TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task OnlyWhatGoesToTheViewerIsHeld()
    {
        // a is the viewer, b is Remote Desktop: a's input reaches b at once even while the path is slow.
        var (viewerEnd, viewer) = Pair();
        var (desktopEnd, desktop) = Pair();
        var splice = Splice.RunAsync(viewer, desktop, roundTripToA: () => TimeSpan.FromSeconds(20));
        var started = System.Diagnostics.Stopwatch.StartNew();
        await viewerEnd.WriteAsync(new byte[] { 1, 2, 3 });
        var buffer = new byte[3];
        await desktopEnd.ReadExactlyAsync(buffer);
        Assert.True(started.Elapsed < TimeSpan.FromMilliseconds(500), $"input took {started.Elapsed}");
        // The other way is held, then still arrives.
        started.Restart();
        await desktopEnd.WriteAsync(new byte[] { 9 });
        await viewerEnd.ReadExactlyAsync(buffer.AsMemory(0, 1));
        Assert.True(started.Elapsed >= Splice.PaceLimit - TimeSpan.FromMilliseconds(100), $"output took {started.Elapsed}");
        viewerEnd.Dispose();
        await splice;
    }

    private static (System.Net.Sockets.NetworkStream, System.Net.Sockets.NetworkStream) Pair()
    {
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var client = new System.Net.Sockets.TcpClient();
        client.Connect((System.Net.IPEndPoint)listener.LocalEndpoint);
        var server = listener.AcceptTcpClient();
        client.NoDelay = server.NoDelay = true;
        return (client.GetStream(), server.GetStream());
    }
}
