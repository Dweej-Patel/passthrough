using System.Collections.Concurrent;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Session;
using Passthrough.Core.Storage;
using Passthrough.Core.Tests.Fakes;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Session;

public class HostSessionTests
{
    private const string AndroidSlot = "token.android.R58M123";
    private const string PhoneToken = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    /// <summary>A session over two fake watchers, with in-memory stores, a fake clock and a client factory that records every client it makes.</summary>
    private sealed class Harness : IAsyncDisposable
    {
        public readonly FakeDeviceWatcher Usb = new(WatchTransport.UsbMux);
        public readonly FakeDeviceWatcher Adb = new(WatchTransport.Adb);
        public readonly ISecretStore Secrets;
        public readonly MemorySettingsStore Settings;
        public readonly FakeTimeProvider Time = new();
        public readonly ConcurrentQueue<(PhoneDevice Device, ControlIdentity Identity, ControlClient Client)> Clients = new();
        public readonly ConcurrentQueue<SessionState> History = new();
        public readonly ConcurrentQueue<Exception> Errors = new();
        public readonly HostSession Session;

        public Harness(MemorySettingsStore? settings = null, ISecretStore? secrets = null)
        {
            Settings = settings ?? new MemorySettingsStore();
            Secrets = secrets ?? new MemorySecretStore();
            Session = new HostSession(new DeviceDirectory([Usb, Adb]), Secrets, Settings, "TEST-PC", Factory, Time);
            Session.StateChanged += History.Enqueue;
            Session.Error += Errors.Enqueue;
        }

        private ControlClient Factory(PhoneDevice device, ControlIdentity identity)
        {
            var client = new ControlClient(ct => device.Connect(ProtocolConstants.ControlPort, ct), identity, device.Kind.Label(), Time);
            Clients.Enqueue((device, identity, client));
            return client;
        }

        public (PhoneDevice Device, ControlIdentity Identity, ControlClient Client) Client(int i) => Clients.ToArray()[i];

        public async Task<SessionState> WaitState(Func<SessionState, bool> done)
        {
            await WaitFor(() => done(Session.State));
            return Session.State;
        }

        public ValueTask DisposeAsync() => Session.DisposeAsync();
    }

    /// <summary>A secret store that fails: on every Set (or only the first <paramref name="failSets"/>), or on Get for one slot.</summary>
    private sealed class FailingSecretStore(bool failSet = false, string? failGetSlot = null, int failSets = 0) : ISecretStore
    {
        private readonly MemorySecretStore _inner = new();
        private int _failSets = failSets;

        public string? Get(string slot) =>
            slot == failGetSlot ? throw new IOException("the credential store is unavailable") : _inner.Get(slot);

        public void Set(string slot, string value)
        {
            if (failSet || Interlocked.Decrement(ref _failSets) >= 0) throw new IOException("the credential store is unavailable");
            _inner.Set(slot, value);
        }

        public void Delete(string slot) => _inner.Delete(slot);
    }

    private static PhoneDevice Android(FakePhone phone) =>
        new("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb, Connect(phone));

    private static PhoneDevice IPhone(FakePhone phone) =>
        new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.00008110-AAAA", WatchTransport.UsbMux, Connect(phone));

    private static PhoneDevice IPad() =>
        new("usbmux:4", PhoneKind.IPad, "00008027…", "token.ipad.00008027-BBBB", WatchTransport.UsbMux,
            (_, _) => throw new InvalidOperationException("an iPad is never connected"));

    private static Func<int, CancellationToken, Task<Stream>> Connect(FakePhone phone) => (port, ct) =>
        port == ProtocolConstants.ControlPort ? phone.Open(ct) : throw new InvalidOperationException($"port {port}");

    private static PhoneEntry? Entry(SessionState s, PhoneDevice d) => s.Phones.FirstOrDefault(p => p.Device.Id == d.Id);

    private static async Task WaitFor(Func<bool> done)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!done())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task ActivePhone_PrefersRoutingPhone_KeepsCurrent()
    {
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var iPad = IPad();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);

        h.Usb.Attach(iPad);
        var s = await h.WaitState(s => Entry(s, iPad) is not null);
        Assert.Equal(PhoneState.RemoteOnlyLater, Entry(s, iPad)!.State);
        Assert.Equal("Pairs once Remote shell is available.", Entry(s, iPad)!.Message);
        Assert.False(Entry(s, iPad)!.IsActive);

        h.Adb.Attach(android);
        s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired });

        h.Usb.Attach(iPhone);
        s = await h.WaitState(s => Entry(s, iPhone) is not null);
        Assert.Equal([iPad, android, iPhone], s.Phones.Select(p => p.Device));
        Assert.True(Entry(s, android)!.IsActive);
        Assert.Equal(new PhoneEntry(iPhone, PhoneState.NotPaired, false, null, 0, 0, 0, null, false), Entry(s, iPhone));
        Assert.Equal(PhoneState.RemoteOnlyLater, Entry(s, iPad)!.State);
        Assert.Equal([android], h.Clients.Select(c => c.Device));
    }

    [Fact]
    public async Task MakeActive_SwitchesChannel()
    {
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);
        h.Adb.Attach(android);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is not null);

        await h.Session.MakeActiveAsync(iPhone.Id);

        Assert.True(h.Client(0).Client.Events.Completion.IsCompleted);
        await androidPhone.WaitClosedAsync();
        var s = await h.WaitState(s => Entry(s, iPhone) is { IsActive: true, State: PhoneState.NotPaired });
        Assert.Equal(new PhoneEntry(android, PhoneState.NotPaired, false, null, 0, 0, 0, null, false), Entry(s, android));
        Assert.Equal([android, iPhone], h.Clients.Select(c => c.Device));
    }

    [Fact]
    public async Task Pairing_StoresTokenInSlot()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken, DeviceName = "Dee's Pixel" };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });

        await h.Session.SubmitCodeAsync(phone.Code);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        var e = Entry(s, android)!;
        Assert.Equal("Dee's Pixel", e.Status!.DeviceName);
        Assert.Equal((1000L, 2000L, 3, (string?)null), (e.Rx, e.Tx, e.Active, e.Message));
        Assert.Contains(h.History, st => Entry(st, android) is { State: PhoneState.Pairing });
        var identity = h.Client(0).Identity;
        Assert.Equal(new ControlIdentity(h.Settings.Get("clientID")!, "TEST-PC", null), identity);
    }

    [Fact]
    public async Task PairingFailure_ShowsMessage()
    {
        await using var phone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });

        await h.Session.SubmitCodeAsync("000000");

        var s = await h.WaitState(s => Entry(s, android)?.Message is not null);
        Assert.Equal("That code didn't match. Check the code on the phone and try again.", Entry(s, android)!.Message);
        Assert.Equal(PhoneState.NotPaired, Entry(s, android)!.State);
        Assert.Null(h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task ProofFailure_KeepsToken()
    {
        await using var phone = new FakePhone { Token = PhoneToken, BadProof = true };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal(
            "The Android phone on the cable could not prove it is paired with this PC. If it is yours, use Forget Pairing in Settings and pair again.",
            Entry(s, android)!.Message);
        Assert.True(Entry(s, android)!.IsActive);
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        Assert.True(Entry(s, android)!.HasPairing);

        h.Time.Advance(TimeSpan.FromSeconds(10));
        await Task.Delay(200);
        Assert.Single(h.Clients);
        Assert.Equal(PhoneState.Failed, Entry(h.Session.State, android)!.State);
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));

        // Made active again: one more try.
        await h.Session.MakeActiveAsync(android.Id);
        await WaitFor(() => h.Clients.Count == 2);
        await WaitFor(() =>
        {
            var states = h.History.Select(st => Entry(st, android)?.State).ToList();
            var failed = states.IndexOf(PhoneState.Failed);
            var retried = states.FindIndex(failed + 1, x => x == PhoneState.Connecting);
            return failed >= 0 && retried > failed && states.Skip(retried).Any(x => x == PhoneState.Failed);
        });
    }

    [Fact]
    public async Task PhoneRejectsAuth_FailsWithItsOwnWording_NotABadCode()
    {
        await using var phone = new FakePhone { Token = PhoneToken, RejectsAuth = true };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal(
            "The Android phone on the cable did not accept this PC's pairing. If it is yours, use Forget Pairing in Settings and pair again.",
            Entry(s, android)!.Message);
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        Assert.DoesNotContain(h.History, st => Entry(st, android)?.Message?.Contains("didn't match") == true);
    }

    [Fact]
    public async Task MalformedStoredToken_CountsAsNotPaired_SlotLeftAlone()
    {
        // The phone would prove a pairing with this string, so only the PC's format check keeps it from being used.
        const string malformed = "short-token";
        await using var phone = new FakePhone { Token = malformed };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, malformed);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired });
        Assert.Null(h.Client(0).Identity.Token);
        Assert.False(Entry(s, android)!.HasPairing);
        Assert.Equal(malformed, h.Secrets.Get(AndroidSlot));
        Assert.DoesNotContain(phone.Received, m => m.T == ControlEnvelope.Auth);
    }

    [Fact]
    public async Task Detach_DuringPairing_ClearsActivePhoneAndStopsClient()
    {
        var gate = new TaskCompletionSource();
        await using var phone = new FakePhone { WelcomeGate = gate.Task };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.Connecting });
        await h.Session.SubmitCodeAsync(phone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Pairing });

        h.Adb.Detach(android);

        var s = await h.WaitState(s => s.Phones.Count == 0);
        await h.Client(0).Client.Events.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        gate.SetResult();
        await phone.WaitClosedAsync();
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await Task.Delay(200);
        Assert.Single(h.Clients);
        Assert.Empty(h.Session.State.Phones);
        Assert.Null(h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task Disconnect_Reconnects()
    {
        await using var phone = new FakePhone { Token = PhoneToken, GoodbyeAfterStatus = true };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        // Paired, then the phone says goodbye and hangs up: back to Connecting, waiting to retry.
        await WaitFor(() =>
        {
            var states = h.History.Select(st => Entry(st, android)?.State).ToList();
            var paired = states.IndexOf(PhoneState.Paired);
            return paired >= 0 && states.Skip(paired).Any(x => x == PhoneState.Connecting);
        });
        Assert.Equal(PhoneState.Connecting, Entry(h.Session.State, android)!.State);
        Assert.Null(Entry(h.Session.State, android)!.Status);

        h.Time.Advance(TimeSpan.FromSeconds(1.9));
        await Task.Delay(200);
        Assert.Single(h.Clients);

        h.Time.Advance(TimeSpan.FromSeconds(0.1));
        await WaitFor(() => h.Clients.Count == 2);
        Assert.Equal(PhoneToken, h.Client(1).Identity.Token);
    }

    [Fact]
    public async Task Forget_DeletesSlotAndDisconnects()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null, HasPairing: true });

        await h.Session.ForgetAsync(android.Id);

        Assert.Null(h.Secrets.Get(AndroidSlot));
        Assert.True(h.Client(0).Client.Events.Completion.IsCompleted);
        // A fresh channel, with no token: the phone counts as unpaired and may pair again.
        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired } && h.Clients.Count == 2);
        Assert.Null(h.Client(1).Identity.Token);
        Assert.Null(Entry(s, android)!.Status);
        Assert.False(Entry(s, android)!.HasPairing);
    }

    [Fact]
    public async Task AndroidDisabled_StopsAdbWatcher()
    {
        await using var phone = new FakePhone();
        var settings = new MemorySettingsStore();
        await using (var h = new Harness(settings))
        {
            await h.Session.StartAsync();
            Assert.Equal((1, 1), (h.Usb.Starts, h.Adb.Starts));
            h.Usb.SetStatus(new WatchStatus(WatchState.Watching));
            h.Adb.SetStatus(new WatchStatus(WatchState.Watching));
            var android = Android(phone);
            h.Adb.Attach(android);
            await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && s.UsbMux.State == WatchState.Watching && s.Adb.State == WatchState.Watching);

            await h.Session.SetAndroidEnabledAsync(false);

            Assert.Equal("false", settings.Get("androidEnabled"));
            Assert.Equal((0, 1), (h.Usb.Stops, h.Adb.Stops));
            var s = await h.WaitState(s => s.Phones.Count == 0 && s.Adb.State == WatchState.Idle);
            Assert.Equal(WatchState.Watching, s.UsbMux.State);
            await h.Client(0).Client.Events.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        }

        // Remembered: the next session leaves adb alone, until it is turned back on.
        await using (var h = new Harness(settings))
        {
            await h.Session.StartAsync();
            Assert.Equal((1, 0), (h.Usb.Starts, h.Adb.Starts));

            await h.Session.SetAndroidEnabledAsync(true);

            Assert.Equal("true", settings.Get("androidEnabled"));
            Assert.Equal(1, h.Adb.Starts);
        }
    }

    [Fact]
    public async Task TokenSaveFailure_FailsAndHoldsOff()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        await using var h = new Harness(secrets: new FailingSecretStore(failSet: true));
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });

        await h.Session.SubmitCodeAsync(phone.Code);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal("Couldn't save the pairing on this PC. Try pairing again.", Entry(s, android)!.Message);
        Assert.IsType<IOException>(Assert.Single(h.Errors));
        // The channel is closed: the status the phone sends after pairing never lands, and nothing reconnects.
        await h.Client(0).Client.Events.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        await phone.WaitClosedAsync();
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await Task.Delay(200);
        Assert.Single(h.Clients);
        Assert.Equal(new PhoneEntry(android, PhoneState.Failed, true, null, 0, 0, 0, "Couldn't save the pairing on this PC. Try pairing again.", false),
            Entry(h.Session.State, android));
        Assert.DoesNotContain(h.History, st => Entry(st, android) is { State: PhoneState.Paired });

        // Made active again: one more try.
        await h.Session.MakeActiveAsync(android.Id);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired } && h.Clients.Count == 2);
    }

    [Fact]
    public async Task Retry_AfterTokenSaveFailure_ReconnectsAndPairs()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        await using var h = new Harness(secrets: new FailingSecretStore(failSets: 1));
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        await h.Session.SubmitCodeAsync(phone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await Task.Delay(200);
        Assert.Single(h.Clients);

        await h.Session.RetryAsync(android.Id);

        // The hold is gone: a fresh channel, the failure message cleared, and the phone may pair again.
        var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && h.Clients.Count == 2);
        Assert.Null(Entry(s, android)!.Message);
        await h.Session.SubmitCodeAsync(phone.Code);
        s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        Assert.True(Entry(s, android)!.HasPairing);
    }

    [Fact]
    public async Task Retry_AfterProofFailure_TriesAgain()
    {
        await using var phone = new FakePhone { Token = PhoneToken, BadProof = true };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });

        await h.Session.RetryAsync(android.Id);

        await WaitFor(() => h.Clients.Count == 2);
        Assert.Equal(PhoneToken, h.Client(1).Identity.Token);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task Retry_PhoneNotActive_MakesItActive()
    {
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);
        h.Adb.Attach(android);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is not null);

        await h.Session.RetryAsync(iPhone.Id);

        await h.WaitState(s => Entry(s, iPhone) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, android) is { IsActive: false });
        Assert.Equal([android, iPhone], h.Clients.Select(c => c.Device));
    }

    [Fact]
    public async Task SlotReadFailure_CountsAsNotPaired_LoopSurvives()
    {
        await using var androidPhone = new FakePhone { IssuedToken = PhoneToken };
        await using var iPhonePhone = new FakePhone();
        var h = new Harness(secrets: new FailingSecretStore(failGetSlot: "token.iphone.00008110-AAAA"));
        try
        {
            await h.Session.StartAsync();
            var android = Android(androidPhone);
            var iPhone = IPhone(iPhonePhone);
            h.Adb.Attach(android);
            h.Usb.Attach(iPhone);

            var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is not null);
            Assert.Equal(PhoneState.NotPaired, Entry(s, iPhone)!.State);
            Assert.NotEmpty(h.Errors);

            // Later calls still run and complete.
            await h.Session.SubmitCodeAsync(androidPhone.Code).WaitAsync(TimeSpan.FromSeconds(10));
            await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
            await h.Session.SetAndroidEnabledAsync(true).WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            await h.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        }
    }
}
