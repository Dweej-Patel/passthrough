using System.Net;
using System.Net.Sockets;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class WatcherTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Nothing listening: every connect is refused at once, as a closed loopback port refuses it. A stub rather than a
    /// port chosen and released, which another test could take before the connect.
    /// </summary>
    private static readonly StreamConnector Refused = _ => throw new SocketException((int)SocketError.ConnectionRefused);

    private static Task<T> NextAsync<T>(Action<Action<T>> subscribe, Func<T, bool> match)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        subscribe(v => { if (match(v)) tcs.TrySetResult(v); });
        return tcs.Task.WaitAsync(Wait);
    }

    private static Dictionary<string, object> Attached(long id, string udid, long product) => new()
    {
        ["MessageType"] = "Attached",
        ["DeviceID"] = id,
        ["Properties"] = new Dictionary<string, object> { ["SerialNumber"] = udid, ["ProductID"] = product, ["ConnectionType"] = "USB" },
    };

    [Fact]
    public async Task UsbMuxWatcher_ReportsIPhoneAndIPad()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(3, "UDID-A", 0x12A8));
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(4, "UDID-B", 0x12AB));
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), TimeProvider.System);
        var two = NextAsync<IReadOnlyList<PhoneDevice>>(h => watcher.DevicesChanged += l => h(l), l => l.Count == 2);
        watcher.Start();

        var devices = await two;
        await watcher.StopAsync();

        Assert.Equal(PhoneKind.IPhone, devices[0].Kind);
        Assert.Equal("token.iphone.UDID-A", devices[0].PairingSlot);
        Assert.Equal("usbmux:3", devices[0].Id);
        Assert.Equal(PhoneKind.IPad, devices[1].Kind);
        Assert.Equal("token.ipad.UDID-B", devices[1].PairingSlot);
        Assert.True(devices[0].CanRoute);
        Assert.False(devices[1].CanRoute);
        Assert.Equal(WatchState.Idle, watcher.Status.State);
    }

    [Fact]
    public async Task UsbMuxWatcher_DetachRemovesDevice()
    {
        var detach = new TaskCompletionSource();
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(3, "UDID-A", 0x12A8));
            await detach.Task;
            await FakeUsbMuxd.WritePacketAsync(s, 0, new Dictionary<string, object> { ["MessageType"] = "Detached", ["DeviceID"] = 3L });
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), TimeProvider.System);
        var one = NextAsync<IReadOnlyList<PhoneDevice>>(h => watcher.DevicesChanged += l => h(l), l => l.Count == 1);
        watcher.Start();
        await one;
        var none = NextAsync<IReadOnlyList<PhoneDevice>>(h => watcher.DevicesChanged += l => h(l), l => l.Count == 0);
        detach.SetResult();

        await none;
        await watcher.StopAsync();
    }

    [Fact]
    public async Task UsbMuxWatcher_NothingListening_ReportsNotInstalled()
    {
        var connector = Refused;
        var watcher = new UsbMuxWatcher(new UsbMuxClient(connector), new FakeTimeProvider());
        var status = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.NotInstalled);
        watcher.Start();

        var seen = await status;
        await watcher.StopAsync();

        Assert.Equal("Install Apple Devices from the Microsoft Store to use an iPhone.", seen.Hint);
    }

    [Fact]
    public async Task UsbMuxWatcher_RetriesEveryFiveSecondsOnTheInjectedClock()
    {
        var attempts = 0;
        StreamConnector connector = _ =>
        {
            Interlocked.Increment(ref attempts);
            throw new SocketException((int)SocketError.ConnectionRefused);
        };
        var time = new FakeTimeProvider();
        var watcher = new UsbMuxWatcher(new UsbMuxClient(connector), time);
        watcher.Start();

        await Poll(() => Volatile.Read(ref attempts) == 1 && time.DueIn().Count == 1);
        Assert.Equal([TimeSpan.FromSeconds(5)], time.DueIn()); // the retry waits on the injected clock, exactly 5 s
        time.Advance(TimeSpan.FromSeconds(5) - TimeSpan.FromMilliseconds(1));
        Assert.Equal(1, Volatile.Read(ref attempts)); // nothing is due yet, so nothing can have run
        time.Advance(TimeSpan.FromMilliseconds(1));
        await Poll(() => Volatile.Read(ref attempts) == 2); // the clock is not moved again: the 5 s deadline alone brings the attempt
        await watcher.StopAsync();
    }

    private static async Task Poll(Func<bool> done)
    {
        var deadline = DateTime.UtcNow + Wait;
        while (!done())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(10);
        }
    }

    private sealed class FakeRunner : IProcessRunner
    {
        public int Runs;
        public Task<int> RunAsync(string exe, string args, CancellationToken ct) { Interlocked.Increment(ref Runs); return Task.FromResult(0); }
    }

    private static AdbLocator Locator(string? found) =>
        new(k => k == "ANDROID_HOME" ? "C:\\sdk" : null, p => found is not null && p == found, ";", "adb.exe");

    [Fact]
    public async Task AdbWatcher_ReportsOnlyUsableDevices()
    {
        await using var fake = new FakeAdbServer(async s =>
        {
            if (await FakeAdbServer.ReadRequestAsync(s) != "host:track-devices-l") return;
            await FakeAdbServer.WriteAsync(s, "OKAY");
            await FakeAdbServer.WriteBlockAsync(s, "R58M123 device usb:1-1 model:Pixel_8\nZZZ unauthorized usb:1-2\n");
            await FakeAdbServer.HoldOpenAsync(s);
        });
        var watcher = new AdbWatcher(new AdbClient(fake.Connector), Locator(null), new FakeRunner(), TimeProvider.System);
        var one = NextAsync<IReadOnlyList<PhoneDevice>>(h => watcher.DevicesChanged += l => h(l), l => l.Count == 1);
        watcher.Start();

        var device = Assert.Single(await one);
        await Poll(() => watcher.Status.State == WatchState.Watching);
        var hint = watcher.Status.Hint;
        await watcher.StopAsync();

        Assert.Equal("token.android.R58M123", device.PairingSlot);
        Assert.Equal("Pixel 8", device.Label);
        Assert.Equal(PhoneKind.Android, device.Kind);
        Assert.Equal("Allow USB debugging on the phone.", hint);
    }

    [Fact]
    public async Task AdbWatcher_NoAdbAndNothingAnswering_ReportsNotInstalled()
    {
        var connector = Refused;
        var runner = new FakeRunner();
        var watcher = new AdbWatcher(new AdbClient(connector), Locator(null), runner, new FakeTimeProvider());
        var status = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.NotInstalled);
        watcher.Start();

        var seen = await status;
        await watcher.StopAsync();

        Assert.Equal("Install Android platform-tools to use an Android phone.", seen.Hint);
        Assert.Equal(0, runner.Runs);
    }

    [Fact]
    public async Task AdbWatcher_AdbInstalledButServerDown_StartsServer()
    {
        var connector = Refused;
        var runner = new FakeRunner();
        var watcher = new AdbWatcher(new AdbClient(connector), Locator("C:\\sdk\\platform-tools\\adb.exe"), runner, new FakeTimeProvider());
        var status = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.Unavailable);
        watcher.Start();

        await status;
        await watcher.StopAsync();

        Assert.True(runner.Runs >= 1);
    }

    [Fact]
    public async Task AdbWatcher_StartsServerAtMostOncePerMinute()
    {
        var connects = 0;
        StreamConnector connector = _ =>
        {
            Interlocked.Increment(ref connects);
            throw new SocketException((int)SocketError.ConnectionRefused);
        };
        var runner = new FakeRunner();
        var time = new FakeTimeProvider();
        var start = time.GetUtcNow();
        var watcher = new AdbWatcher(new AdbClient(connector), Locator("C:\\sdk\\platform-tools\\adb.exe"), runner, time);
        watcher.Start();

        await Poll(() => Volatile.Read(ref connects) >= 2);
        Assert.Equal(1, runner.Runs);
        // Retry every 5 s; the second start is allowed only once 60 s have passed.
        await Poll(() => { time.Advance(TimeSpan.FromSeconds(5)); return Volatile.Read(ref runner.Runs) == 2; });
        Assert.True(time.GetUtcNow() - start >= TimeSpan.FromSeconds(60));
        await watcher.StopAsync();
    }

    [Fact]
    public async Task Watcher_StopThenImmediateStart_NewRunsDevicesSurvive()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(3, "UDID-A", 0x12A8));
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), TimeProvider.System);
        var lists = new System.Collections.Concurrent.ConcurrentQueue<int>();
        watcher.DevicesChanged += l => lists.Enqueue(l.Count);
        watcher.Start();
        await Poll(() => lists.Contains(1));

        var stop = watcher.StopAsync();
        watcher.Start();
        await stop;
        await Poll(() => lists.ToArray() is [.., 1] && lists.Count >= 3);

        Assert.Equal(WatchState.Watching, await WaitState(watcher));
        await watcher.StopAsync();
    }

    private static async Task<WatchState> WaitState(IDeviceWatcher w)
    {
        await Poll(() => w.Status.State == WatchState.Watching);
        return w.Status.State;
    }

    [Fact]
    public async Task Watcher_ConcurrentStops_BothReturnOnlyAfterTheRunEnded()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), TimeProvider.System);
        watcher.Start();
        await Poll(() => watcher.Status.State == WatchState.Watching);

        var a = watcher.StopAsync();
        var b = watcher.StopAsync();
        await Task.WhenAll(a, b).WaitAsync(Wait);

        Assert.Equal(WatchState.Idle, watcher.Status.State);
    }

    [Fact]
    public async Task UsbMuxWatcher_DaemonThatNeverAnswers_ReportsUnavailableNotStuckStarting()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.HoldOpenAsync(s); // takes the Listen, never answers
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector, TimeSpan.FromMilliseconds(200)), new FakeTimeProvider());
        var status = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State != WatchState.Starting);
        watcher.Start();

        var seen = await status;
        await watcher.StopAsync();

        // Apple Devices answered the connect, so it is installed: not the install hint.
        Assert.Equal(new WatchStatus(WatchState.Unavailable), seen);
    }

    private sealed class HangingRunner : IProcessRunner
    {
        public int Runs;
        public int Killed;

        public async Task<int> RunAsync(string exe, string args, CancellationToken ct)
        {
            Interlocked.Increment(ref Runs);
            try { await Task.Delay(Timeout.InfiniteTimeSpan, ct); }
            catch (OperationCanceledException) { Interlocked.Increment(ref Killed); throw; }
            return 0;
        }
    }

    [Fact]
    public async Task AdbWatcher_StartServerThatHangs_KilledAfter15Seconds_ReportsUnavailable()
    {
        var runner = new HangingRunner();
        var time = new FakeTimeProvider();
        var watcher = new AdbWatcher(new AdbClient(Refused), Locator("C:\\sdk\\platform-tools\\adb.exe"), runner, time);
        var unavailable = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.Unavailable);
        watcher.Start();

        await Poll(() => Volatile.Read(ref runner.Runs) == 1 && time.DueIn().Count == 1);
        Assert.Equal(WatchState.Starting, watcher.Status.State);
        time.Advance(AdbClient.ServerStartTimeout);

        await unavailable;
        Assert.Equal(1, Volatile.Read(ref runner.Killed));
        await watcher.StopAsync();
    }

    /// <summary>A watcher whose run publishes a phone, says it is watching, then fails (a bug in a run, or a subscriber).</summary>
    private sealed class FaultyWatcher(TimeProvider time) : WatcherBase(WatchTransport.UsbMux, time)
    {
        public int Runs;

        protected override Task RunAsync(CancellationToken ct)
        {
            Interlocked.Increment(ref Runs);
            Publish([Phone("usbmux:3")]);
            SetStatus(new WatchStatus(WatchState.Watching));
            throw new InvalidOperationException("the run broke");
        }
    }

    private static PhoneDevice Phone(string id) =>
        new(id, PhoneKind.IPhone, id, "token.iphone." + id, WatchTransport.UsbMux, (_, _) => throw new NotSupportedException());

    [Fact]
    public async Task Watcher_RunThatFaults_ClearsItsPhones_Reports_RetriesAndStopsCleanly()
    {
        var time = new FakeTimeProvider();
        var watcher = new FaultyWatcher(time);
        var lists = new System.Collections.Concurrent.ConcurrentQueue<int>();
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        watcher.DevicesChanged += l => lists.Enqueue(l.Count);
        watcher.Error += errors.Enqueue;
        watcher.Start();

        await Poll(() => watcher.Status.State == WatchState.Unavailable && time.DueIn().Count == 1);
        Assert.Equal([1, 0], lists); // the phone it published is withdrawn
        Assert.Equal("the run broke", Assert.Single(errors).Message);
        time.Advance(time.DueIn()[0]);
        await Poll(() => Volatile.Read(ref watcher.Runs) == 2); // it starts over, as a watcher does after any failure

        await watcher.StopAsync().WaitAsync(Wait); // does not throw
        Assert.Equal(WatchState.Idle, watcher.Status.State);
        Assert.Equal(0, lists.Last());
    }

    [Fact]
    public async Task AdbWatcher_LocatorThatThrows_ReportsAndStopDoesNotThrow()
    {
        var locator = new AdbLocator(_ => throw new UnauthorizedAccessException("environment unreadable"), _ => false, ";", "adb.exe");
        var watcher = new AdbWatcher(new AdbClient(Refused), locator, new FakeRunner(), new FakeTimeProvider());
        var error = NextAsync<Exception>(h => watcher.Error += h, _ => true);
        watcher.Start();

        Assert.IsType<UnauthorizedAccessException>(await error);
        await watcher.StopAsync().WaitAsync(Wait);
        Assert.Equal(WatchState.Idle, watcher.Status.State);
    }

    [Fact]
    public async Task Watcher_SubscriberThatThrows_DoesNotReachOtherSubscribersOrTheRun()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(3, "UDID-A", 0x12A8));
            await FakeUsbMuxd.HoldOpenAsync(s);
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), new FakeTimeProvider());
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        watcher.Error += errors.Enqueue;
        watcher.DevicesChanged += _ => throw new InvalidOperationException("a broken subscriber");
        watcher.StatusChanged += _ => throw new InvalidOperationException("a broken subscriber");
        var one = NextAsync<IReadOnlyList<PhoneDevice>>(h => watcher.DevicesChanged += l => h(l), l => l.Count == 1);
        watcher.Start();

        await one;
        await Poll(() => watcher.Status.State == WatchState.Watching);
        Assert.Equal(1, fake.Accepted); // the listen was not torn down and redone
        Assert.All(errors, e => Assert.Equal("a broken subscriber", e.Message));
        await watcher.StopAsync();
    }

    [Fact]
    public async Task UsbMuxWatcher_DaemonFailure_ReportedOnceUntilWatchingAgain()
    {
        var listens = 0;
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            // The first two listens are refused; the third is accepted, then dropped; the fourth is refused again.
            var n = Interlocked.Increment(ref listens);
            await FakeUsbMuxd.WriteResultAsync(s, tag, n == 3 ? 0 : 6);
        });
        var time = new FakeTimeProvider();
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), time);
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        watcher.Error += errors.Enqueue;
        watcher.Start();

        for (var attempt = 1; attempt <= 4; attempt++)
        {
            await Poll(() => fake.Accepted == attempt && time.DueIn().Count == 1); // failed, waiting to retry
            if (attempt < 4) time.Advance(time.DueIn()[0]);
        }
        await watcher.StopAsync();

        Assert.Collection(errors,
            e => Assert.Equal(6, Assert.IsType<UsbMuxException>(e).ResultCode), // attempts 1 and 2: once
            e => Assert.IsType<EndOfStreamException>(e),                        // attempt 3: watching, then dropped
            e => Assert.Equal(6, Assert.IsType<UsbMuxException>(e).ResultCode)); // attempt 4: after watching, again
    }

    [Fact]
    public async Task AdbWatcher_StartServerThatHangs_IsReported()
    {
        var time = new FakeTimeProvider();
        var runner = new HangingRunner();
        var watcher = new AdbWatcher(new AdbClient(Refused), Locator("C:\\sdk\\platform-tools\\adb.exe"), runner, time);
        var error = NextAsync<Exception>(h => watcher.Error += h, _ => true);
        watcher.Start();

        await Poll(() => Volatile.Read(ref runner.Runs) == 1 && time.DueIn().Count == 1);
        time.Advance(AdbClient.ServerStartTimeout);

        Assert.Equal("adb start-server did not finish within 15 seconds", Assert.IsType<TimeoutException>(await error).Message);
        await watcher.StopAsync();
    }

    [Fact]
    public async Task UsbMuxWatcher_ListenEnds_ClearsItsPhonesAndReportsUnavailable()
    {
        await using var fake = new FakeUsbMuxd(async s =>
        {
            var (_, _, _, tag, _) = await FakeUsbMuxd.ReadPacketAsync(s);
            await FakeUsbMuxd.WriteResultAsync(s, tag, 0);
            await FakeUsbMuxd.WritePacketAsync(s, 0, Attached(3, "UDID-A", 0x12A8));
            // then usbmuxd closes the connection (Apple Devices quit)
        });
        var watcher = new UsbMuxWatcher(new UsbMuxClient(fake.Connector), new FakeTimeProvider());
        var lists = new System.Collections.Concurrent.ConcurrentQueue<int>();
        watcher.DevicesChanged += l => lists.Enqueue(l.Count);
        var unavailable = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.Unavailable);
        watcher.Start();

        Assert.Equal(new WatchStatus(WatchState.Unavailable), await unavailable);
        Assert.Equal([1, 0], lists);
        await watcher.StopAsync();
    }

    [Fact]
    public async Task AdbWatcher_TrackEnds_ClearsItsPhonesAndReportsUnavailable()
    {
        await using var fake = new FakeAdbServer(async s =>
        {
            if (await FakeAdbServer.ReadRequestAsync(s) != "host:track-devices-l") return;
            await FakeAdbServer.WriteAsync(s, "OKAY");
            await FakeAdbServer.WriteBlockAsync(s, "R58M123 device usb:1-1\n");
            // then the adb server goes away
        });
        var watcher = new AdbWatcher(new AdbClient(fake.Connector), Locator("C:\\sdk\\platform-tools\\adb.exe"), new FakeRunner(), new FakeTimeProvider());
        var lists = new System.Collections.Concurrent.ConcurrentQueue<int>();
        watcher.DevicesChanged += l => lists.Enqueue(l.Count);
        var unavailable = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.Unavailable);
        watcher.Start();

        Assert.Equal(new WatchStatus(WatchState.Unavailable), await unavailable);
        Assert.Equal([1, 0], lists);
        await watcher.StopAsync();
    }

    [Theory]
    [InlineData("R58M123 offline usb:1-1\n", "The Android phone is offline to adb. Replug the cable.")]
    [InlineData("R58M123 no permissions usb:1-1\n", "adb can't access the Android phone. Replug the cable and choose File Transfer if asked.")]
    public async Task AdbWatcher_UnusablePhone_Hint(string block, string hint)
    {
        await using var fake = new FakeAdbServer(async s =>
        {
            if (await FakeAdbServer.ReadRequestAsync(s) != "host:track-devices-l") return;
            await FakeAdbServer.WriteAsync(s, "OKAY");
            await FakeAdbServer.WriteBlockAsync(s, block);
            await FakeAdbServer.HoldOpenAsync(s);
        });
        var watcher = new AdbWatcher(new AdbClient(fake.Connector), Locator(null), new FakeRunner(), new FakeTimeProvider());
        var lists = new System.Collections.Concurrent.ConcurrentQueue<int>();
        watcher.DevicesChanged += l => lists.Enqueue(l.Count);
        var watching = NextAsync<WatchStatus>(h => watcher.StatusChanged += h, s => s.State == WatchState.Watching);
        watcher.Start();

        Assert.Equal(new WatchStatus(WatchState.Watching, hint), await watching);
        Assert.Equal([0], lists); // listed by adb, but not usable: no phone reported
        await watcher.StopAsync();
    }
}
