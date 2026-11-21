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
        public readonly ISettingsStore Settings;
        public readonly FakeTimeProvider Time = new();
        public readonly ConcurrentQueue<(PhoneDevice Device, ControlIdentity Identity, ControlClient Client)> Clients = new();
        public readonly ConcurrentQueue<SessionState> History = new();
        public readonly ConcurrentQueue<Exception> Errors = new();
        public readonly ConcurrentQueue<string> Log = new();
        public readonly HostSession Session;

        public Harness(ISettingsStore? settings = null, ISecretStore? secrets = null)
        {
            Settings = settings ?? new MemorySettingsStore();
            Secrets = secrets ?? new MemorySecretStore();
            Session = new HostSession(new DeviceDirectory([Usb, Adb]), Secrets, Settings, "TEST-PC", Factory, Time);
            Session.StateChanged += History.Enqueue;
            Session.Error += Errors.Enqueue;
            Session.Log += Log.Enqueue;
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

        /// <summary>Waits until the reconnect timer is armed for <paramref name="delay"/>, then fires it; returns once the next client exists.</summary>
        public async Task FireReconnect(TimeSpan delay, int clientsAfter)
        {
            await WaitFor(() => Time.DueIn().Contains(delay));
            Time.Advance(delay - TimeSpan.FromMilliseconds(1));
            Assert.Equal(clientsAfter - 1, Clients.Count); // not a moment early
            Time.Advance(TimeSpan.FromMilliseconds(1));
            await WaitFor(() => Clients.Count == clientsAfter);
        }

        /// <summary>
        /// Returns once every piece of work queued on the session so far has run: a timer that fired during an
        /// <c>Advance</c> queued its work before this call, so a negative check after it is decided, not timed.
        /// </summary>
        public Task Settle() => Session.PairedSlotsAsync();

        /// <summary>Submits a code to <paramref name="device"/> as the flyout does: addressed by its id and current attachment.</summary>
        public Task<bool> Submit(PhoneDevice device, string code) =>
            Session.SubmitCodeAsync(device.Id, Entry(Session.State, device)!.Attachment, code);

        public ValueTask DisposeAsync() => Session.DisposeAsync();
    }

    /// <summary>
    /// A secret store that fails: on every Set (or only the first <paramref name="failSets"/>), or on Get for one slot
    /// until <see cref="Healed"/>. Counts Gets.
    /// </summary>
    private sealed class FailingSecretStore(bool failSet = false, string? failGetSlot = null, int failSets = 0, bool failGetOnlyWhenStored = false) : ISecretStore
    {
        private readonly MemorySecretStore _inner = new();
        private int _failSets = failSets;
        private int _gets;

        public volatile bool Healed;

        public int Gets => Volatile.Read(ref _gets);

        /// <summary>With <c>failGetOnlyWhenStored</c>: a file that exists but is locked; once deleted, Get reads nothing.</summary>
        public string? Get(string slot)
        {
            Interlocked.Increment(ref _gets);
            var fails = slot == failGetSlot && !Healed && (!failGetOnlyWhenStored || _inner.Get(slot) is not null);
            return fails ? throw new IOException("the credential store is unavailable") : _inner.Get(slot);
        }

        public void Set(string slot, string value)
        {
            if (failSet || Interlocked.Decrement(ref _failSets) >= 0) throw new IOException("the credential store is unavailable");
            _inner.Set(slot, value);
        }

        public void Delete(string slot) => _inner.Delete(slot);

        public IReadOnlyList<string> Slots() => _inner.Slots();
    }

    /// <summary>A settings store whose first <paramref name="failSets"/> writes fail (a full disk).</summary>
    private sealed class FailingSettingsStore(int failSets) : ISettingsStore
    {
        private readonly MemorySettingsStore _inner = new();
        private int _failSets = failSets;

        public string? Get(string key) => _inner.Get(key);

        public void Set(string key, string value)
        {
            if (Interlocked.Decrement(ref _failSets) >= 0) throw new IOException("There is not enough space on the disk.");
            _inner.Set(key, value);
        }
    }

    private static PhoneDevice Android(FakePhone phone) =>
        new("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb, Connect(phone));

    private static PhoneDevice IPhone(FakePhone phone) =>
        new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.00008110-AAAA", WatchTransport.UsbMux, Connect(phone));

    private static PhoneDevice IPad(FakePhone phone) =>
        new("usbmux:4", PhoneKind.IPad, "00008027…", "token.ipad.00008027-BBBB", WatchTransport.UsbMux, Connect(phone));

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
    public async Task EveryDeviceGetsAChannel_TheActiveMarkerPrefersARoutingPhoneAndStays()
    {
        await using var iPadPhone = new FakePhone();
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var iPad = IPad(iPadPhone);
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);

        h.Usb.Attach(iPad);
        var s = await h.WaitState(s => Entry(s, iPad) is { State: PhoneState.NotPaired });
        Assert.False(Entry(s, iPad)!.IsActive); // an iPad carries no internet: never the active one

        h.Adb.Attach(android);
        s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired });

        h.Usb.Attach(iPhone);
        s = await h.WaitState(s => Entry(s, iPhone) is { State: PhoneState.NotPaired });
        Assert.Equal([iPad, android, iPhone], s.Phones.Select(p => p.Device));
        Assert.True(Entry(s, android)!.IsActive); // the marker stays where it was
        Assert.Equal(new PhoneEntry(iPhone, PhoneState.NotPaired, false, null, 0, 0, 0, null, false, Entry(s, iPhone)!.Attachment), Entry(s, iPhone));
        Assert.Equal([iPad, android, iPhone], h.Clients.Select(c => c.Device));
    }

    [Fact]
    public async Task IPad_PairsLikeAPhone()
    {
        await using var iPadPhone = new FakePhone { IssuedToken = PhoneToken, DeviceName = "Dee's iPad" };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var iPad = IPad(iPadPhone);
        h.Usb.Attach(iPad);
        await h.WaitState(s => Entry(s, iPad) is { State: PhoneState.NotPaired });

        Assert.True(await h.Submit(iPad, iPadPhone.Code));
        var s = await h.WaitState(s => Entry(s, iPad) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal("Dee's iPad", Entry(s, iPad)!.Status!.DeviceName);
        Assert.Equal(PhoneToken, h.Secrets.Get("token.ipad.00008027-BBBB"));
        Assert.False(Entry(s, iPad)!.IsActive);
    }

    [Fact]
    public async Task MakeActive_MovesTheMarker_BothKeepTheirChannels()
    {
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);
        h.Adb.Attach(android);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is { State: PhoneState.NotPaired });

        await h.Session.MakeActiveAsync(iPhone.Id);

        var s = await h.WaitState(s => Entry(s, iPhone) is { IsActive: true, State: PhoneState.NotPaired });
        Assert.False(h.Client(0).Client.Events.Completion.IsCompleted); // the Android phone's channel stays open
        Assert.Equal(new PhoneEntry(android, PhoneState.NotPaired, false, null, 0, 0, 0, null, false, Entry(s, android)!.Attachment), Entry(s, android));
        Assert.Equal([android, iPhone], h.Clients.Select(c => c.Device)); // no channel was opened for the move
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

        await h.Submit(android, phone.Code);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        var e = Entry(s, android)!;
        Assert.Equal("Dee's Pixel", e.Status!.DeviceName);
        Assert.Equal((1000L, 2000L, 3, (string?)null), (e.Rx, e.Tx, e.Active, e.Message));
        Assert.Contains(h.History, st => Entry(st, android) is { State: PhoneState.Pairing });
        var identity = h.Client(0).Identity;
        Assert.Equal(new ControlIdentity(h.Settings.Get("clientID")!, "TEST-PC", null), identity);
    }

    [Theory]
    [InlineData("bad_code", "That code didn't match. Check the digits on the Android phone.")]
    [InlineData("expired", "The code expired or wasn't generated yet. Tap Pair on the Android phone and try again.")]
    [InlineData("not_authenticated", "Not authenticated.")]
    [InlineData("code_withdrawn", "Too many wrong codes were tried, so the Android phone withdrew that code. Tap Pair on the Android phone for a new one, then type it here.")]
    [InlineData("something_new", "That code didn't match. Check the digits on the Android phone.")]
    public async Task PairingFailure_ShowsTheMacsWording(string reason, string message)
    {
        await using var phone = new FakePhone { PairError = reason };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });

        await h.Submit(android, phone.Code);

        var s = await h.WaitState(s => Entry(s, android)?.Message is not null);
        Assert.Equal(message, Entry(s, android)!.Message);
        Assert.Equal(PhoneState.NotPaired, Entry(s, android)!.State);
        Assert.Null(h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task Locked_SaysTypeItAgain_AndOpensAFreshChannelAtOnce()
    {
        // The phone closes a channel after three wrong codes; the code still works on a new one (as on the Mac).
        await using var phone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var iPhone = IPhone(phone);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, iPhone) is { State: PhoneState.NotPaired });
        foreach (var code in new[] { "000000", "000001" })
        {
            await h.Submit(iPhone, code);
            await h.WaitState(s => Entry(s, iPhone) is { State: PhoneState.NotPaired, Message: not null });
        }

        await h.Submit(iPhone, "000002");

        var s = await h.WaitState(s => Entry(s, iPhone)?.Message?.Contains("again") == true && h.Clients.Count == 2);
        Assert.Equal("That code didn't match again. Check the digits on the iPhone, then type them once more.", Entry(s, iPhone)!.Message);
        Assert.Equal(PhoneState.NotPaired, Entry(s, iPhone)!.State);
        var states = h.History.Select(st => Entry(st, iPhone)?.State).ToList();
        Assert.DoesNotContain(PhoneState.Connecting, states.Skip(states.IndexOf(PhoneState.NotPaired))); // the box never went away
        // The right code now pairs on the fresh channel, without waiting for a reconnect.
        await h.Submit(iPhone, phone.Code);
        await h.WaitState(s => Entry(s, iPhone) is { State: PhoneState.Paired, Status: not null });
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
        await h.Settle();
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
        await h.Submit(android, phone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Pairing });

        h.Adb.Detach(android);

        var s = await h.WaitState(s => s.Phones.Count == 0);
        await h.Client(0).Client.Events.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        gate.SetResult();
        await phone.WaitClosedAsync();
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await h.Settle();
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
        await h.Settle();
        Assert.Single(h.Clients);

        h.Time.Advance(TimeSpan.FromSeconds(0.1));
        await WaitFor(() => h.Clients.Count == 2);
        Assert.Equal(PhoneToken, h.Client(1).Identity.Token);
    }

    [Fact]
    public async Task Code_AddressedToAnotherPhone_IsNotSent()
    {
        await using var androidPhone = new FakePhone();
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);
        h.Adb.Attach(android);
        h.Usb.Attach(iPhone);
        var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is { State: PhoneState.NotPaired });
        var androidRow = Entry(s, android)!;

        // A row's attachment number names that row only: it never sends a code to another device.
        Assert.False(await h.Session.SubmitCodeAsync(iPhone.Id, androidRow.Attachment, iPhonePhone.Code));
        await h.WaitState(s => Entry(s, iPhone) is { State: PhoneState.NotPaired });
        Assert.DoesNotContain(iPhonePhone.Received, m => m.T == ControlEnvelope.Pair);

        // Any attached device takes its own code, active or not.
        await h.Session.MakeActiveAsync(iPhone.Id);
        Assert.True(await h.Session.SubmitCodeAsync(android.Id, androidRow.Attachment, androidPhone.Code));
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, IsActive: false });
        Assert.DoesNotContain(iPhonePhone.Received, m => m.T == ControlEnvelope.Pair);
    }

    [Fact]
    public async Task Code_ForAnEarlierAttachment_IsNotSent()
    {
        await using var phone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        var before = Entry(await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired }), android)!;
        h.Adb.Detach(android);
        await h.WaitState(s => s.Phones.Count == 0);
        h.Adb.Attach(android);
        var after = Entry(await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired }), android)!;
        Assert.NotEqual(before.Attachment, after.Attachment);

        Assert.False(await h.Session.SubmitCodeAsync(android.Id, before.Attachment, phone.Code));
        Assert.Equal(PhoneState.NotPaired, Entry(h.Session.State, android)!.State);

        Assert.True(await h.Session.SubmitCodeAsync(android.Id, after.Attachment, phone.Code));
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
    }

    [Fact]
    public async Task Code_WhileWaitingToReconnect_OpensAChannelAtOnceAndSendsIt()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        var refusals = 1;
        var android = new PhoneDevice("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb,
            (port, ct) => Interlocked.Decrement(ref refusals) >= 0 ? Task.FromException<Stream>(new AdbException("closed")) : phone.Open(ct));
        await using var h = new Harness();
        await h.Session.StartAsync();
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, Message: not null });
        await WaitFor(() => h.Time.DueIn().Contains(TimeSpan.FromSeconds(2)));

        Assert.True(await h.Submit(android, phone.Code));

        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(2, h.Clients.Count); // no waiting out the back-off
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task Code_WhileTheChannelIsClosingButNotYetReported_GoesOnAFreshChannel()
    {
        // The client has closed, but its Disconnected is still queued behind the code: the code must not be dropped.
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        var block = 0;
        using var release = new ManualResetEventSlim();
        var blocked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        h.Session.StateChanged += _ =>
        {
            if (Interlocked.Exchange(ref block, 0) != 1) return;
            blocked.SetResult();
            release.Wait(TimeSpan.FromSeconds(10)); // holds the session loop
        };
        Interlocked.Exchange(ref block, 1);
        h.Usb.SetStatus(new WatchStatus(WatchState.Watching));
        await blocked.Task.WaitAsync(TimeSpan.FromSeconds(10));

        var submitted = h.Submit(android, phone.Code); // queued first
        await h.Client(0).Client.DisposeAsync(); // closed; its Disconnected queues behind the code
        release.Set();

        Assert.True(await submitted.WaitAsync(TimeSpan.FromSeconds(10)));
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(2, h.Clients.Count); // a fresh channel at once, no back-off
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
    }

    [Fact]
    public async Task Code_ForAPairedPhoneStillConnecting_IsNotSent()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { Token = PhoneToken, WelcomeGate = gate.Task };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, HasPairing: true });

        Assert.False(await h.Submit(android, phone.Code));

        gate.SetResult();
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.DoesNotContain(phone.Received, m => m.T == ControlEnvelope.Pair);
    }

    [Fact]
    public void ReconnectDelay_BacksOffLikeTheMac()
    {
        Assert.Equal([2, 4, 6, 28, 30, 30], new[] { 1, 2, 3, 14, 15, 40 }.Select(n => HostSession.ReconnectDelay(n).TotalSeconds));
    }

    [Fact]
    public async Task AppNotRunning_SaysSo_BacksOff_LogsOnce()
    {
        var android = new PhoneDevice("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb,
            (_, _) => Task.FromException<Stream>(new AdbException("closed")));
        await using var h = new Harness();
        await h.Session.StartAsync();
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, Message: not null });
        Assert.Equal("Passthrough isn't running on the Android phone. Start it there, then connect.", Entry(s, android)!.Message);
        await h.FireReconnect(TimeSpan.FromSeconds(2), clientsAfter: 2);
        await h.FireReconnect(TimeSpan.FromSeconds(4), clientsAfter: 3);
        await h.FireReconnect(TimeSpan.FromSeconds(6), clientsAfter: 4);

        await WaitFor(() => h.Time.DueIn().Contains(TimeSpan.FromSeconds(8)));
        var line = Assert.Single(h.Log);
        Assert.Equal("adb:R58M123 (Android phone): channel closed: AppNotRunning; retrying", line);
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task Welcome_ClearsTheReason_AndStartsTheBackOffOver()
    {
        // Refused twice, then Passthrough on the phone is up: it pairs, says goodbye and hangs up.
        await using var phone = new FakePhone { Token = PhoneToken, GoodbyeAfterStatus = true };
        var refusals = 2;
        var android = new PhoneDevice("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb,
            (port, ct) => Interlocked.Decrement(ref refusals) >= 0 ? Task.FromException<Stream>(new AdbException("closed")) : phone.Open(ct));
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        h.Adb.Attach(android);
        await h.FireReconnect(TimeSpan.FromSeconds(2), clientsAfter: 2);
        await h.FireReconnect(TimeSpan.FromSeconds(4), clientsAfter: 3);

        await WaitFor(() => h.History.Any(st => Entry(st, android) is { State: PhoneState.Paired, Message: null }));
        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, Message: not null });
        Assert.Equal("The Android phone closed the connection.", Entry(s, android)!.Message);
        await h.FireReconnect(TimeSpan.FromSeconds(2), clientsAfter: 4);
        Assert.Equal(
            [
                "adb:R58M123 (Android phone): channel closed: AppNotRunning; retrying",
                "adb:R58M123 (Android phone): Passthrough was turned off on the phone", // its goodbye
                "adb:R58M123 (Android phone): channel closed: PhoneClosed; retrying",
            ],
            h.Log.Take(3));
    }

    [Fact]
    public async Task Code_WhoseChannelNeverOpened_IsKeptForTheNextOne_AndSentOnce()
    {
        // Refused twice: the code is typed during the first back-off, and its own channel is refused too. The
        // flyout has cleared the box, so the code must not be lost: it waits (Pairing) and goes out on the next channel.
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        var refusals = 2;
        var android = new PhoneDevice("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb,
            (port, ct) => Interlocked.Decrement(ref refusals) >= 0 ? Task.FromException<Stream>(new AdbException("closed")) : phone.Open(ct));
        await using var h = new Harness();
        await h.Session.StartAsync();
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, Message: not null });
        await WaitFor(() => h.Time.DueIn().Contains(TimeSpan.FromSeconds(2)));

        Assert.True(await h.Submit(android, phone.Code));

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Pairing, Message: not null } && h.Time.DueIn().Count > 0);
        Assert.Equal("Passthrough isn't running on the Android phone. Start it there, then connect.", Entry(s, android)!.Message);
        Assert.False(await h.Submit(android, "111111")); // one code at a time: Pair stays disabled while it waits

        await h.FireReconnect(TimeSpan.FromSeconds(4), clientsAfter: 3);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal(PhoneToken, h.Secrets.Get(AndroidSlot));
        var pair = Assert.Single(phone.Received, m => m.T == ControlEnvelope.Pair);
        Assert.Equal(phone.Code, pair.Code);
    }

    [Fact]
    public async Task Code_KeptForTheNextChannel_IsDroppedWhenAnotherPhoneIsMadeActive()
    {
        await using var other = new FakePhone();
        var android = new PhoneDevice("adb:R58M123", PhoneKind.Android, "Pixel 8", AndroidSlot, WatchTransport.Adb,
            (_, _) => Task.FromException<Stream>(new AdbException("closed")));
        await using var h = new Harness();
        await h.Session.StartAsync();
        h.Adb.Attach(android);
        await WaitFor(() => h.Time.DueIn().Contains(TimeSpan.FromSeconds(2)));
        Assert.True(await h.Submit(android, "042917"));
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Pairing } && h.Time.DueIn().Count > 0);

        var iphone = IPhone(other);
        h.Usb.Attach(iphone);
        await h.WaitState(s => Entry(s, iphone) is not null);
        await h.Session.MakeActiveAsync(iphone.Id);
        await h.Session.MakeActiveAsync(android.Id);

        // Active again, and refused again: back to Connecting with the reason, no code waiting (Pair can be pressed).
        var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.Connecting, Message: not null });
        Assert.True(Core.Presentation.PhoneRowModel.From(Entry(s, android)!).CanPair);
    }

    [Fact]
    public async Task UnpairedPhone_ClosesIdleChannel_ReopensAtOnce_StaysNotPaired()
    {
        // A phone closes an unauthenticated channel after 10 s unless a code is showing: the code box must not flap.
        var close = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { CloseAfterWelcomeGate = close.Task };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });

        h.Time.Advance(TimeSpan.FromSeconds(9));
        close.SetResult();

        await WaitFor(() => h.Clients.Count == 2);
        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        Assert.Null(Entry(s, android)!.Message);
        var states = h.History.Select(st => Entry(st, android)?.State).ToList();
        Assert.DoesNotContain(PhoneState.Connecting, states.Skip(states.IndexOf(PhoneState.NotPaired)));
        Assert.Empty(h.Log);
    }

    [Fact]
    public async Task UnpairedPhone_ClosesAtOnce_BacksOffInstead()
    {
        // Something that closes channels at once must not be reopened in a tight loop.
        await using var phone = new FakePhone { CloseAfterWelcome = true };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Connecting, Message: not null });
        Assert.Equal("The Android phone closed the connection.", Entry(s, android)!.Message);
        await h.FireReconnect(TimeSpan.FromSeconds(2), clientsAfter: 2);
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
    public async Task ForgetSlot_PhoneNotAttached_DeletesTheToken()
    {
        // A phone that was sold or lost can still be forgotten.
        await using var h = new Harness();
        h.Secrets.Set("token.iphone.GONE", PhoneToken);
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();

        Assert.Equal([AndroidSlot, "token.iphone.GONE"], await h.Session.PairedSlotsAsync());
        await h.Session.ForgetSlotAsync("token.iphone.GONE");

        Assert.Null(h.Secrets.Get("token.iphone.GONE"));
        Assert.Equal([AndroidSlot], await h.Session.PairedSlotsAsync());
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task ForgetSlot_OfTheActivePhone_ReopensItUnpaired()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, HasPairing: true });

        await h.Session.ForgetSlotAsync(AndroidSlot);

        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired, HasPairing: false } && h.Clients.Count == 2);
        Assert.Null(h.Client(1).Identity.Token);
    }

    [Fact]
    public async Task Forget_SlotUnreadable_StillDeletes_AndReopensAChannelThatUsedIt()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        var secrets = new FailingSecretStore(failGetSlot: AndroidSlot, failGetOnlyWhenStored: true) { Healed = true };
        await using var h = new Harness(secrets: secrets);
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, HasPairing: true });
        secrets.Healed = false; // the file is locked now: reading it fails, deleting it works

        await h.Session.ForgetAsync(android.Id);

        Assert.DoesNotContain(AndroidSlot, secrets.Slots());
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired, HasPairing: false } && h.Clients.Count == 2);
        Assert.Null(h.Client(1).Identity.Token);
        Assert.Empty(h.Errors);
    }

    [Fact]
    public async Task Forget_Twice_IsNotAnError_AndChangesNothingMore()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var h = new Harness();
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, HasPairing: true });

        await h.Session.ForgetAsync(android.Id);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired } && h.Clients.Count == 2);
        await h.Session.ForgetAsync(android.Id);
        await h.Session.ForgetSlotAsync(AndroidSlot);
        await h.Session.ForgetAsync("adb:NOT-ATTACHED");

        Assert.Equal(2, h.Clients.Count); // the unpaired channel was left alone
        Assert.Equal(PhoneState.NotPaired, Entry(h.Session.State, android)!.State);
        Assert.Empty(h.Errors);
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

        await h.Submit(android, phone.Code);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal("Couldn't save the pairing on this PC. Try pairing again.", Entry(s, android)!.Message);
        Assert.IsType<IOException>(Assert.Single(h.Errors));
        // The channel is closed: the status the phone sends after pairing never lands, and nothing reconnects.
        await h.Client(0).Client.Events.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        await phone.WaitClosedAsync();
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await h.Settle();
        Assert.Single(h.Clients);
        Assert.Equal(new PhoneEntry(android, PhoneState.Failed, true, null, 0, 0, 0, "Couldn't save the pairing on this PC. Try pairing again.", false,
            Entry(h.Session.State, android)!.Attachment), Entry(h.Session.State, android));
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
        await h.Submit(android, phone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        h.Time.Advance(TimeSpan.FromSeconds(10));
        await h.Settle();
        Assert.Single(h.Clients);

        await h.Session.RetryAsync(android.Id);

        // The hold is gone: a fresh channel, the failure message cleared, and the phone may pair again.
        var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && h.Clients.Count == 2);
        Assert.Null(Entry(s, android)!.Message);
        await h.Submit(android, phone.Code);
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
    public async Task Retry_PhoneNotActive_ReopensOnlyItsChannel()
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

        await h.WaitState(s => Entry(s, iPhone) is { IsActive: false, State: PhoneState.NotPaired } && Entry(s, android) is { IsActive: true });
        Assert.Equal([android, iPhone, iPhone], h.Clients.Select(c => c.Device)); // a fresh channel for the iPhone alone
        Assert.False(h.Client(0).Client.Events.Completion.IsCompleted);
    }

    [Fact]
    public async Task ActiveSlotReadFailure_FailsWithTryAgain_ThenRetryOpens()
    {
        await using var phone = new FakePhone();
        var secrets = new FailingSecretStore(failGetSlot: AndroidSlot);
        await using var h = new Harness(secrets: secrets);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.True(Entry(s, android)!.IsActive);
        Assert.Equal("Couldn't read this PC's saved pairings or settings. Try again.", Entry(s, android)!.Message);
        Assert.Contains(h.Errors, e => e is IOException);
        h.Time.Advance(TimeSpan.FromSeconds(60));
        await h.Settle();
        Assert.Empty(h.Clients);
        Assert.Equal(PhoneState.Failed, Entry(h.Session.State, android)!.State);
        secrets.Healed = true;

        await h.Session.RetryAsync(android.Id);

        s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        Assert.Null(Entry(s, android)!.Message);
        Assert.Single(h.Clients);
    }

    [Fact]
    public async Task ClientIdWriteFailure_FailsWithTryAgain_ThenRetryOpens()
    {
        await using var phone = new FakePhone();
        await using var h = new Harness(settings: new FailingSettingsStore(failSets: 1));
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);

        var s = await h.WaitState(s => Entry(s, android) is { State: PhoneState.Failed });
        Assert.Equal("Couldn't read this PC's saved pairings or settings. Try again.", Entry(s, android)!.Message);
        Assert.Contains(h.Errors, e => e is IOException);
        Assert.Empty(h.Clients);

        await h.Session.RetryAsync(android.Id);

        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        Assert.Equal(h.Settings.Get("clientID"), h.Client(0).Identity.ClientId);
    }

    [Fact]
    public async Task Snapshots_DoNotReadTheSlots_EachTime()
    {
        await using var androidPhone = new FakePhone { Token = PhoneToken };
        await using var iPhonePhone = new FakePhone();
        var secrets = new FailingSecretStore(failGetSlot: "token.iphone.00008110-AAAA");
        await using var h = new Harness(secrets: secrets);
        h.Secrets.Set(AndroidSlot, PhoneToken);
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        var iPhone = IPhone(iPhonePhone);
        h.Adb.Attach(android);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null, HasPairing: true } && Entry(s, iPhone) is { HasPairing: false });
        var gets = secrets.Gets;
        var errors = h.Errors.Count;

        for (var i = 0; i < 10; i++) h.Usb.SetStatus(new WatchStatus(i % 2 == 0 ? WatchState.Watching : WatchState.Starting));
        await h.WaitState(s => s.UsbMux.State == WatchState.Starting);

        Assert.Equal(gets, secrets.Gets); // one read per slot, not one per snapshot
        Assert.Equal(errors, h.Errors.Count); // and an unreadable slot is reported once, not on every snapshot
        Assert.Equal(1, errors);
    }

    [Fact]
    public async Task Pairing_ThenForget_HasPairingFollows()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken };
        var secrets = new FailingSecretStore();
        await using var h = new Harness(secrets: secrets);
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired, HasPairing: false });

        await h.Submit(android, phone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, HasPairing: true });

        await h.Session.ForgetAsync(android.Id);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired, HasPairing: false });
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

            var s = await h.WaitState(s => Entry(s, android) is { IsActive: true, State: PhoneState.NotPaired } && Entry(s, iPhone) is { State: PhoneState.Failed });
            // Its own channel could not read its slot: that row fails (with Try again), the Android phone is unaffected.
            Assert.Equal("Couldn't read this PC's saved pairings or settings. Try again.", Entry(s, iPhone)!.Message);
            Assert.NotEmpty(h.Errors);

            // Later calls still run and complete.
            await h.Submit(android, androidPhone.Code).WaitAsync(TimeSpan.FromSeconds(10));
            await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
            await h.Session.SetAndroidEnabledAsync(true).WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            await h.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        }
    }

    [Fact]
    public async Task PairedPhone_ItsNameIsSaved_AndItKeepsItsStatusWhenNoLongerActive()
    {
        await using var androidPhone = new FakePhone { IssuedToken = PhoneToken, DeviceName = "Dee's Pixel" };
        await using var iPhonePhone = new FakePhone();
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(androidPhone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired, SavedName: null });

        await h.Submit(android, androidPhone.Code);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.Paired, Status: not null });
        Assert.Equal("Dee's Pixel", DeviceNames.Get(h.Settings, AndroidSlot));

        var iPhone = IPhone(iPhonePhone);
        h.Usb.Attach(iPhone);
        await h.WaitState(s => Entry(s, iPhone) is not null);
        await h.Session.MakeActiveAsync(iPhone.Id);
        var s = await h.WaitState(s => Entry(s, android) is { IsActive: false });
        Assert.Equal((PhoneState.Paired, "Dee's Pixel"), (Entry(s, android)!.State, Entry(s, android)!.SavedName));
        Assert.Equal("Dee's Pixel", Entry(s, android)!.Status!.DeviceName); // its channel stays: its status stays live
    }

    [Fact]
    public async Task ForgetSlot_AlsoForgetsTheSavedName()
    {
        await using var phone = new FakePhone { IssuedToken = PhoneToken, DeviceName = "Dee's Pixel" };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var android = Android(phone);
        h.Adb.Attach(android);
        await h.WaitState(s => Entry(s, android) is { State: PhoneState.NotPaired });
        await h.Submit(android, phone.Code);
        await h.WaitState(s => Entry(s, android) is { SavedName: "Dee's Pixel" });

        await h.Session.ForgetSlotAsync(AndroidSlot);

        await h.WaitState(s => Entry(s, android) is { HasPairing: false, SavedName: null });
        Assert.Null(DeviceNames.Get(h.Settings, AndroidSlot));
    }

    [Fact]
    public async Task SerialsThatFilterAlike_KeepTheirOwnTokens_AndForgetOnlyItsOwn()
    {
        const string otherToken = "ZZECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
        await using var plusPhone = new FakePhone { IssuedToken = PhoneToken };
        await using var plainPhone = new FakePhone { IssuedToken = otherToken };
        await using var h = new Harness();
        await h.Session.StartAsync();
        var plus = new PhoneDevice("adb:A+B", PhoneKind.Android, "A+B", PhoneDevice.SlotFor(PhoneKind.Android, "A+B"), WatchTransport.Adb, Connect(plusPhone));
        var plain = new PhoneDevice("adb:AB", PhoneKind.Android, "AB", PhoneDevice.SlotFor(PhoneKind.Android, "AB"), WatchTransport.Adb, Connect(plainPhone));
        Assert.NotEqual(plus.PairingSlot, plain.PairingSlot);

        h.Adb.Attach(plus);
        await h.WaitState(s => Entry(s, plus) is { IsActive: true, State: PhoneState.NotPaired });
        await h.Submit(plus, plusPhone.Code);
        await h.WaitState(s => Entry(s, plus) is { State: PhoneState.Paired, HasPairing: true });

        h.Adb.Attach(plain);
        await h.WaitState(s => Entry(s, plain) is { State: PhoneState.NotPaired, HasPairing: false }); // the other's token isn't its
        await h.Session.MakeActiveAsync(plain.Id);
        await h.WaitState(s => Entry(s, plain) is { IsActive: true, State: PhoneState.NotPaired });
        await h.Submit(plain, plainPhone.Code);
        await h.WaitState(s => Entry(s, plain) is { State: PhoneState.Paired, HasPairing: true });

        Assert.Equal(PhoneToken, h.Secrets.Get(plus.PairingSlot));
        Assert.Equal(otherToken, h.Secrets.Get(plain.PairingSlot));

        await h.Session.ForgetSlotAsync(plus.PairingSlot);

        Assert.Null(h.Secrets.Get(plus.PairingSlot));
        Assert.Equal(otherToken, h.Secrets.Get(plain.PairingSlot));
        await h.WaitState(s => Entry(s, plus) is { HasPairing: false } && Entry(s, plain) is { State: PhoneState.Paired, HasPairing: true });
    }
}
