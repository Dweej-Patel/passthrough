using Passthrough.Core.Screen;
using Passthrough.Windows.Screen;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>This PC's own Remote Desktop, read only: what the service would see. Nothing is changed.</summary>
public sealed class RemoteDesktopTests
{
    [Fact]
    public void TheFactsCanBeRead()
    {
        var facts = RemoteDesktopProbe.Read();
        Assert.InRange(facts.Port, 1, 65535);
        Assert.NotNull(facts.FirewallOnEveryProfile);
    }

    [Fact]
    public async Task WhenRemoteDesktopRunsTheRelaysDialFindsItGenuineAndItsCertificate()
    {
        var facts = RemoteDesktopProbe.Read();
        if (facts.Denied || !facts.ServiceRunning) return; // not on here (a CI runner may have it off)
        var gate = new RemoteDesktopGate(() => null, _ => false);
        await using var dial = await gate.DialAsync(facts.Port, CancellationToken.None);
        Assert.NotNull(dial);
        var pin = await gate.CertificateSha256Async(CancellationToken.None);
        Assert.Matches("^[0-9a-f]{64}$", pin!);
    }

    [Fact]
    public async Task SomethingElseOnThePortIsNotRemoteDesktop()
    {
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        _ = listener.AcceptTcpClientAsync();
        var gate = new RemoteDesktopGate(() => null, _ => false);
        Assert.Null(await gate.DialAsync(port, CancellationToken.None));
    }
}
