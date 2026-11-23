using System.Net;
using System.Net.Sockets;
using Passthrough.Core.Cable;
using Passthrough.Core.Transport;
using Passthrough.Windows.Cable;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>The cable peer check against a stand-in: this test process listening where usbmuxd or adb would.</summary>
public sealed class CablePeerCheckTests
{
    private static async Task<(Stream Stream, TcpListener Listener, TcpClient Accepted)> StandIn()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var stream = await ByteStreamConnector.Tcp("127.0.0.1", ((IPEndPoint)listener.LocalEndpoint).Port)(CancellationToken.None);
        var accepted = await listener.AcceptTcpClientAsync();
        return (stream, listener, accepted);
    }

    [Fact]
    public async Task AStandInForApplesServiceIsNotGenuine()
    {
        var (stream, listener, accepted) = await StandIn();
        using (accepted)
        await using (stream)
        {
            // This test process is neither the Apple service's nor Apple Devices' packaged process.
            Assert.Equal(PeerVerdict.NotGenuine, CablePeerCheck.Check(stream, PhoneKind.IPhone));
            Assert.Equal(PeerVerdict.NotGenuine, CablePeerCheck.Check(stream, PhoneKind.IPad));
        }
        listener.Stop();
    }

    [Fact]
    public async Task AnAdbAsThisUserInThisSessionIsGenuine()
    {
        var (stream, listener, accepted) = await StandIn();
        using (accepted)
        await using (stream)
        {
            // The far end is this process: this user, this session (what an adb this user started is).
            Assert.Equal(PeerVerdict.Genuine, CablePeerCheck.Check(stream, PhoneKind.Android));
            var owner = CablePeerCheck.OwnerOf((IPEndPoint)listener.LocalEndpoint, (IPEndPoint)accepted.Client.RemoteEndPoint!);
            Assert.Equal(Environment.ProcessId, owner);
        }
        listener.Stop();
    }

    /// <summary>Where Apple's device service runs (a PC with Apple Devices or iTunes): the real usbmuxd is genuine.</summary>
    [Fact]
    public async Task TheRealUsbmuxdIsGenuineWhereItRuns()
    {
        Stream stream;
        try { stream = await ByteStreamConnector.Tcp("127.0.0.1", 27015)(CancellationToken.None); }
        catch (SocketException) { return; } // no usbmuxd here (CI): nothing to check
        await using (stream) Assert.Equal(PeerVerdict.Genuine, CablePeerCheck.Check(stream, PhoneKind.IPhone));
    }

    [Fact]
    public void AStreamWithoutEndsCantBeTold()
    {
        Assert.Equal(PeerVerdict.Unknown, CablePeerCheck.Check(new MemoryStream(), PhoneKind.Android));
    }
}
