using System.Net.Sockets;
using System.Text;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class AdbClientTests
{
    private static CancellationToken Deadline() => new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token;

    private static async Task<IReadOnlyList<AdbDevice>> FirstListAsync(string block)
    {
        await using var fake = new FakeAdbServer(async s =>
        {
            Assert.Equal("host:track-devices-l", await FakeAdbServer.ReadRequestAsync(s));
            await FakeAdbServer.WriteAsync(s, "OKAY");
            await FakeAdbServer.WriteBlockAsync(s, block);
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new AdbClient(fake.Connector);
        await foreach (var list in client.TrackDevicesAsync(Deadline())) return list;
        throw new InvalidOperationException("no list");
    }

    [Fact]
    public async Task Track_ParsesAndFiltersDevices()
    {
        var list = await FirstListAsync(
            "R58M123 device product:x model:Pixel_8 device:y\n" +
            "emulator-5554 device\n" +
            "192.168.1.5:5555 device\n");

        Assert.Equal(new[] { new AdbDevice("R58M123", "device", "Pixel_8") }, list);
    }

    [Fact]
    public async Task Track_UnauthorizedDeviceIsListedNotUsable()
    {
        var list = await FirstListAsync("R58M123 unauthorized\n");

        var device = Assert.Single(list);
        Assert.Equal("R58M123", device.Serial);
        Assert.False(device.IsUsable);
    }

    [Fact]
    public async Task Track_TwoWordStateIsKept()
    {
        var list = await FirstListAsync("R58M123 no permissions usb:1-2 model:P\n");

        Assert.Equal("no permissions", Assert.Single(list).State);
    }

    [Fact]
    public async Task Track_EmptyBlockYieldsEmptyList()
    {
        Assert.Empty(await FirstListAsync(""));
    }

    [Theory]
    [InlineData("adb-ABC123-xyz._adb-tls-connect._tcp", true)]
    [InlineData("emulator-5554", true)]
    [InlineData("10.0.0.2:5555", true)]
    [InlineData("R58M123", false)]
    public void IsIgnored_MatchesWifiAndEmulators(string serial, bool ignored) =>
        Assert.Equal(ignored, AdbDevice.IsIgnored(serial));

    [Fact]
    public async Task Connect_SendsTransportThenTcpPort()
    {
        var seen = new List<string>();
        await using var fake = new FakeAdbServer(async s =>
        {
            seen.Add(await FakeAdbServer.ReadRequestAsync(s));
            await FakeAdbServer.WriteAsync(s, "OKAY");
            seen.Add(await FakeAdbServer.ReadRequestAsync(s));
            await FakeAdbServer.WriteAsync(s, "OKAY");
            var buf = new byte[2];
            await s.ReadExactlyAsync(buf);
            await s.WriteAsync(buf);
            await s.FlushAsync();
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new AdbClient(fake.Connector);

        await using var stream = await client.ConnectAsync("R58M123", 7891, Deadline());
        await stream.WriteAsync(Encoding.ASCII.GetBytes("hi"));
        await stream.FlushAsync();
        var echo = new byte[2];
        await stream.ReadExactlyAsync(echo);

        Assert.Equal(new[] { "host:transport:R58M123", "tcp:7891" }, seen);
        Assert.Equal("hi", Encoding.ASCII.GetString(echo));
    }

    [Fact]
    public async Task Connect_Fail_ThrowsWithMessage()
    {
        await using var fake = new FakeAdbServer(async s =>
        {
            await FakeAdbServer.ReadRequestAsync(s);
            await FakeAdbServer.WriteAsync(s, "FAIL0010device not found");
            await Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline());
        });
        var client = new AdbClient(fake.Connector);

        var e = await Assert.ThrowsAsync<AdbException>(() => client.ConnectAsync("R58M123", 7891, Deadline()));
        Assert.Equal("device not found", e.Message);
    }

    [Fact]
    public async Task Connect_SilentServer_TimesOut()
    {
        await using var fake = new FakeAdbServer(s => Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline()));
        var client = new AdbClient(fake.Connector, TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAsync<TimeoutException>(() => client.ConnectAsync("R58M123", 7891, Deadline()));
    }

    private sealed class RecordingRunner : IProcessRunner
    {
        public List<(string Exe, string Args)> Calls { get; } = [];

        public Task<int> RunAsync(string exe, string args, CancellationToken ct)
        {
            Calls.Add((exe, args));
            return Task.FromResult(0);
        }
    }

    [Fact]
    public async Task EnsureServer_StartsServerWhenNothingAnswers()
    {
        await using var fake = new FakeAdbServer(s => Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline()));
        var attempts = 0;
        var client = new AdbClient(async ct =>
        {
            if (attempts++ == 0) throw new SocketException((int)SocketError.ConnectionRefused);
            return await fake.Connector(ct);
        });
        var runner = new RecordingRunner();

        await AdbClient.EnsureServerAsync(client, "C:\\sdk\\adb.exe", runner, Deadline());

        Assert.Equal(new[] { ("C:\\sdk\\adb.exe", "start-server") }, runner.Calls);
        Assert.Equal(2, attempts);
    }

    [Fact]
    public async Task EnsureServer_ServerAlreadyUp_DoesNotRunAdb()
    {
        await using var fake = new FakeAdbServer(s => Task.Delay(System.Threading.Timeout.InfiniteTimeSpan, Deadline()));
        var runner = new RecordingRunner();

        await AdbClient.EnsureServerAsync(new AdbClient(fake.Connector), "adb", runner, Deadline());

        Assert.Empty(runner.Calls);
    }

    [Fact]
    public async Task EnsureServer_NoAdbBinary_Throws()
    {
        var client = new AdbClient(_ => throw new SocketException((int)SocketError.ConnectionRefused));
        var runner = new RecordingRunner();

        await Assert.ThrowsAsync<SocketException>(() => AdbClient.EnsureServerAsync(client, null, runner, Deadline()));
        Assert.Empty(runner.Calls);
    }
}
