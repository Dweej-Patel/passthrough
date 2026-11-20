using System.Text;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class UsbMuxClientTests
{
    private static CancellationToken Deadline() => new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token;

    [Fact]
    public async Task Listen_ReportsAttachAndDetach()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object>
            {
                ["MessageType"] = "Attached",
                ["DeviceID"] = 3L,
                ["Properties"] = new Dictionary<string, object> { ["SerialNumber"] = "UDID-A", ["ProductID"] = 0x12A8L },
            });
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object>
            {
                ["MessageType"] = "Detached",
                ["DeviceID"] = 3L,
            });
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new UsbMuxClient(fake.Connector);
        var ct = Deadline();

        var events = new List<UsbMuxEvent>();
        await foreach (var e in client.ListenAsync(ct))
        {
            events.Add(e);
            if (events.Count == 2) break;
        }

        Assert.Equal(new UsbMuxEvent.Attached(new UsbMuxDevice(3, "UDID-A", 0x12A8)), events[0]);
        Assert.Equal(new UsbMuxEvent.Detached(3), events[1]);
    }

    [Fact]
    public async Task Listen_SendsVersion1PlistHeader()
    {
        var seen = new TaskCompletionSource<(uint, uint, uint, uint, Dictionary<string, object>)>();
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var p = await FakeUsbMuxd.ReadPacketAsync(s);
            seen.TrySetResult(p);
            await FakeUsbMuxd.WriteResultAsync(s, p.Tag, 0);
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new UsbMuxClient(fake.Connector);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var pump = Task.Run(async () =>
        {
            try { await foreach (var _ in client.ListenAsync(cts.Token)) { } }
            catch (OperationCanceledException) { }
        });

        var (length, version, type, tag, plist) = await seen.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cts.Cancel();
        await pump;

        Assert.Equal(1u, version);
        Assert.Equal(8u, type);
        Assert.Equal(1u, tag);
        Assert.Equal((uint)(16 + Plist.Encode(plist).Length), length);
        Assert.Equal("Listen", plist["MessageType"]);
        Assert.Equal("Passthrough", plist["ClientVersionString"]);
        Assert.Equal("Passthrough", plist["ProgName"]);
    }

    [Fact]
    public async Task Connect_SendsPortInNetworkOrderAndReturnsStream()
    {
        var seen = new TaskCompletionSource<Dictionary<string, object>>();
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var p = await FakeUsbMuxd.ReadPacketAsync(s);
            seen.TrySetResult(p.Plist);
            await FakeUsbMuxd.WriteResultAsync(s, p.Tag, 0);
            var buf = new byte[2];
            await s.ReadExactlyAsync(buf);
            await s.WriteAsync(buf);
            await s.FlushAsync();
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new UsbMuxClient(fake.Connector);

        await using var stream = await client.ConnectAsync(3, 7891, Deadline());
        await stream.WriteAsync(Encoding.ASCII.GetBytes("hi"));
        await stream.FlushAsync();
        var echo = new byte[2];
        await stream.ReadExactlyAsync(echo, Deadline());

        var msg = await seen.Task;
        Assert.Equal("Connect", msg["MessageType"]);
        Assert.Equal(3L, msg["DeviceID"]);
        // 7891 = 0x1ED3; usbmuxd wants the 16-bit byte swap, 0xD31E. (The brief said 0x931E, a typo.)
        Assert.Equal(0xD31EL, msg["PortNumber"]);
        Assert.Equal("hi", Encoding.ASCII.GetString(echo));
    }

    [Fact]
    public async Task Connect_Refused_Throws()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var p = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, p.Tag, 3);
        });
        var client = new UsbMuxClient(fake.Connector);

        var ex = await Assert.ThrowsAsync<UsbMuxException>(() => client.ConnectAsync(3, 7891, Deadline()));

        Assert.Equal(3, ex.ResultCode);
    }
}
