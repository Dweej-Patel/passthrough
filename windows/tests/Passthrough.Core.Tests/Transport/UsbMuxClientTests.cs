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
                ["Properties"] = new Dictionary<string, object> { ["SerialNumber"] = "UDID-A", ["ProductID"] = 0x12A8L, ["ConnectionType"] = "USB" },
            });
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object>
            {
                ["MessageType"] = "Detached",
                ["DeviceID"] = 3L,
            });
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var client = new UsbMuxClient(fake.Connector);
        var ct = Deadline();

        var events = new List<UsbMuxEvent>();
        await foreach (var e in client.ListenAsync(ct))
        {
            events.Add(e);
            if (events.Count == 2) break;
        }

        Assert.Equal(new UsbMuxEvent.Attached(new UsbMuxDevice(3, "UDID-A", 0x12A8, "USB")), events[0]);
        Assert.Equal(new UsbMuxEvent.Detached(3), events[1]);
    }

    /// <summary>The exact Listen request body: pinned bytes, not decoded with the codec that wrote them.</summary>
    private const string ListenBody =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
        "<plist version=\"1.0\"><dict>" +
        "<key>MessageType</key><string>Listen</string>" +
        "<key>ClientVersionString</key><string>Passthrough</string>" +
        "<key>ProgName</key><string>Passthrough</string>" +
        "<key>kLibUSBMuxVersion</key><integer>3</integer>" +
        "</dict></plist>";

    [Fact]
    public async Task Listen_SendsExactlyThisPacket()
    {
        var seen = new TaskCompletionSource<(uint, uint, uint, uint, byte[])>();
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var p = await FakeUsbMuxd.ReadRawPacketAsync(s);
            seen.TrySetResult(p);
            await FakeUsbMuxd.WriteResultAsync(s, p.Tag, 0);
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var client = new UsbMuxClient(fake.Connector);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var pump = Task.Run(async () =>
        {
            try { await foreach (var _ in client.ListenAsync(cts.Token)) { } }
            catch (OperationCanceledException) { }
        });

        var (length, version, type, tag, body) = await seen.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cts.Cancel();
        await pump;

        Assert.Equal(1u, version);
        Assert.Equal(8u, type);
        Assert.Equal(1u, tag);
        Assert.Equal(ListenBody, Encoding.UTF8.GetString(body));
        Assert.Equal((uint)(16 + Encoding.UTF8.GetByteCount(ListenBody)), length);
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
            await FakeUsbMuxd.HoldOpenAsync(s);
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

    [Fact]
    public async Task Listen_IgnoresNetworkDevices()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            foreach (var (id, type) in new[] { (5L, "Network"), (6L, "USB") })
                await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object>
                {
                    ["MessageType"] = "Attached",
                    ["DeviceID"] = id,
                    ["Properties"] = new Dictionary<string, object> { ["SerialNumber"] = $"U{id}", ["ProductID"] = 0x12A8L, ["ConnectionType"] = type },
                });
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object> { ["MessageType"] = "Detached", ["DeviceID"] = 5L });
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object> { ["MessageType"] = "Detached", ["DeviceID"] = 6L });
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var client = new UsbMuxClient(fake.Connector);

        var events = new List<UsbMuxEvent>();
        await foreach (var e in client.ListenAsync(Deadline()))
        {
            events.Add(e);
            if (events.Count == 2) break;
        }

        Assert.Equal(new UsbMuxEvent.Attached(new UsbMuxDevice(6, "U6", 0x12A8, "USB")), events[0]);
        Assert.Equal(new UsbMuxEvent.Detached(6), events[1]);
    }

    [Fact]
    public async Task Connect_UnresponsiveDaemon_TimesOut()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var client = new UsbMuxClient(fake.Connector, TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAsync<TimeoutException>(() => client.ConnectAsync(3, 7891, Deadline()));
    }
}
