using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Control;

public class ControlClientTests
{
    private const string ClientId = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    private const string PcName = "TEST-PC";
    private const string PhoneToken = "phone-token-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

    private static ControlClient Client(FakePhone phone, string? token, TimeProvider? time = null) =>
        new(phone.Open, new ControlIdentity(ClientId, PcName, token), "iPhone", time ?? new FakeTimeProvider());

    private static async Task<ControlEvent> NextAsync(ControlClient client)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        return await client.Events.ReadAsync(deadline.Token);
    }

    /// <summary>Every event left, up to the channel completing.</summary>
    private static async Task<List<ControlEvent>> RestAsync(ControlClient client)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var events = new List<ControlEvent>();
        await foreach (var e in client.Events.ReadAllAsync(deadline.Token)) events.Add(e);
        return events;
    }

    private static async Task<Exception?> DisconnectErrorAsync(ControlClient client)
    {
        var events = await RestAsync(client);
        var last = Assert.IsType<ControlEvent.Disconnected>(events[^1]);
        Assert.Single(events, e => e is ControlEvent.Disconnected);
        return last.Error;
    }

    [Fact]
    public async Task Paired_ValidProof_SendsAuthAndReportsStatus()
    {
        await using var phone = new FakePhone { Token = PhoneToken, DeviceName = "Dee's iPhone" };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        var status = Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));
        Assert.Equal("Dee's iPhone", status.Status.DeviceName);
        Assert.Equal(new DeviceStatus("Dee's iPhone", "5G", "Carrier", 0.5, "foreground", true, null), status.Status);
        Assert.Equal((1000L, 2000L, 3), (status.Rx, status.Tx, status.Active));

        var received = phone.Received;
        Assert.Equal(new[] { ControlEnvelope.Hello, ControlEnvelope.Auth }, received.Select(m => m.T));
        var hello = received[0];
        Assert.Equal(2, hello.ProtocolVersion);
        Assert.Equal("usb", hello.Via);
        Assert.Equal(ClientId, hello.ClientID);
        Assert.Equal(PcName, hello.Name);
        var macNonce = ControlAuth.DecodeNonce(hello.Nonce);
        Assert.NotNull(macNonce);
        var expected = ControlAuth.MacProof(ControlAuth.Key(PhoneToken), ClientId, macNonce, phone.PhoneNonce!);
        Assert.Equal(Convert.ToBase64String(expected), received[1].Proof);
    }

    [Fact]
    public async Task PairedWithBadProof_SendsNothingAndFailsWithProofFailed()
    {
        await using var phone = new FakePhone { Token = PhoneToken, BadProof = true };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.ProofFailed, error.Kind);
        Assert.Equal(
            "The iPhone on the cable could not prove it is paired with this PC. If it is yours, use Forget Pairing in Settings and pair again.",
            error.Message);
        await phone.WaitClosedAsync();
        Assert.Equal(new[] { ControlEnvelope.Hello }, phone.Received.Select(m => m.T));
    }

    [Fact]
    public async Task Unpaired_SubmitCode_PairsAndReturnsToken()
    {
        await using var phone = new FakePhone { IssuedToken = "fresh-token" };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("042917");

        Assert.Equal(new ControlEvent.PairedWith("fresh-token"), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));
        var pair = Assert.Single(phone.Received, m => m.T == ControlEnvelope.Pair);
        Assert.Equal(("042917", ClientId, PcName), (pair.Code, pair.ClientID, pair.Name));
    }

    [Fact]
    public async Task CodeBeforeWelcome_SentAfterWelcome()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { WelcomeGate = gate.Task };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        await client.SubmitCodeAsync("042917");
        gate.SetResult();

        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        Assert.IsType<ControlEvent.PairedWith>(await NextAsync(client));
        var transcript = phone.Transcript;
        Assert.Equal(["recv hello", "sent welcome", "recv pair", "sent paired"], transcript.Take(4));
    }

    [Fact]
    public async Task WrongCode_ReportsBadCode()
    {
        await using var phone = new FakePhone();
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("000000");

        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.BadCode), await NextAsync(client));
    }

    [Fact]
    public async Task ThirdWrongCode_ReportsLocked()
    {
        await using var phone = new FakePhone();
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("000000");
        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.BadCode), await NextAsync(client));
        await client.SubmitCodeAsync("000001");
        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.BadCode), await NextAsync(client));
        await client.SubmitCodeAsync("000002");

        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.Locked), await NextAsync(client));
        Assert.Null(await DisconnectErrorAsync(client)); // the phone closes after locked
    }

    [Fact]
    public async Task Withdrawn_ReportsCodeWithdrawn()
    {
        await using var phone = new FakePhone { PriorWrongGuesses = 9 };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("000000");

        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.CodeWithdrawn), await NextAsync(client));
    }

    [Fact]
    public async Task UnsolicitedPaired_BeforeOurPairIsWritten_Ignored()
    {
        // The code is entered before the welcome, so the pair is queued the moment the welcome is read; its write
        // is held off the wire while the phone plants a paired (then a bad_code marker) right behind the welcome.
        var welcomeGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { WelcomeGate = welcomeGate.Task, UnsolicitedPairedToken = "planted-token", IssuedToken = "real-token" };
        GatedStream? gated = null;
        await using var client = new ControlClient(
            async ct => gated = new GatedStream(await phone.Open(ct), b => b.Span.IndexOf("\"t\":\"pair\""u8) >= 0),
            new ControlIdentity(ClientId, PcName, null), "iPhone", new FakeTimeProvider());

        await client.StartAsync(CancellationToken.None);
        await client.SubmitCodeAsync("042917");
        welcomeGate.SetResult();

        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.BadCode), await NextAsync(client)); // the planted paired was read and ignored
        gated!.Release();
        Assert.Equal(new ControlEvent.PairedWith("real-token"), await NextAsync(client));
    }

    [Fact]
    public async Task DelayedWelcome_NoPingBeforeProof_BadProofStillSendsNothing()
    {
        var time = new FakeTimeProvider();
        var welcomeGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { Token = PhoneToken, BadProof = true, WelcomeGate = welcomeGate.Task };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => phone.Transcript.Contains("recv hello"));
        time.Advance(TimeSpan.FromSeconds(6)); // a heartbeat tick falls inside the handshake
        await Task.Delay(100); // give a wrongly queued ping time to reach the wire
        welcomeGate.SetResult();

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.ProofFailed, error.Kind);
        await phone.WaitClosedAsync();
        Assert.Equal(new[] { ControlEnvelope.Hello }, phone.Received.Select(m => m.T));
    }

    [Fact]
    public async Task NoWelcome_DisconnectsAfter20Seconds()
    {
        var time = new FakeTimeProvider();
        var welcomeGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { WelcomeGate = welcomeGate.Task };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        time.Advance(TimeSpan.FromSeconds(21));

        Assert.IsType<TimeoutException>(await DisconnectErrorAsync(client));
        welcomeGate.SetResult();
    }

    [Fact]
    public async Task OlderPhone_IncompatiblePhoneIsOlder()
    {
        await using var phone = new FakePhone { ProtocolVersion = 1 };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.Incompatible, error.Kind);
        Assert.True(error.PhoneIsOlder);
        Assert.Equal("Passthrough on the iPhone is out of date. Update it on the iPhone, then connect again.", error.Message);
    }

    [Fact]
    public async Task NewerPhone_IncompatiblePcIsOlder()
    {
        await using var phone = new FakePhone { ProtocolVersion = 3, RejectsOtherVersions = false, Token = PhoneToken };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.Incompatible, error.Kind);
        Assert.False(error.PhoneIsOlder);
        Assert.Equal("Passthrough on this PC is out of date. Update it on this PC, then connect again.", error.Message);
        await phone.WaitClosedAsync();
        Assert.Equal(new[] { ControlEnvelope.Hello }, phone.Received.Select(m => m.T));
    }

    [Fact]
    public async Task Silent_DisconnectsAfter20Seconds()
    {
        var time = new FakeTimeProvider();
        await using var phone = new FakePhone { Token = PhoneToken, SilentAfterStatus = true };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));

        time.Advance(TimeSpan.FromSeconds(21));

        Assert.IsType<TimeoutException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task OnlyUnknownMessages_DisconnectsAfter20Seconds()
    {
        var time = new FakeTimeProvider();
        await using var phone = new FakePhone { Token = PhoneToken, ChattersInsteadOfPong = true };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));

        // Each ping is answered with a message of an unknown type, which is not an answer.
        for (var i = 1; i <= 3; i++)
        {
            time.Advance(TimeSpan.FromSeconds(5));
            await WaitUntilAsync(() => phone.Transcript.Count(l => l == "sent chatter") >= i);
            await Task.Delay(50); // let the client read it before the clock moves on
        }
        time.Advance(TimeSpan.FromSeconds(5));

        Assert.IsType<TimeoutException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task Answering_StaysConnectedPast20Seconds()
    {
        var time = new FakeTimeProvider();
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));

        // Each step lets a ping go out and its pong come back before the clock moves on.
        for (var i = 0; i < 6; i++)
        {
            var pongs = phone.Transcript.Count(l => l == "sent pong");
            time.Advance(TimeSpan.FromSeconds(5));
            await WaitUntilAsync(() => phone.Transcript.Count(l => l == "sent pong") > pongs);
        }

        Assert.False(client.Events.Completion.IsCompleted);
        Assert.Equal(6, phone.Received.Count(m => m.T == ControlEnvelope.Ping));
    }

    [Fact]
    public async Task OversizedLine_Disconnects()
    {
        var garbage = new byte[ProtocolConstants.MaxLineBytes + 1];
        Array.Fill(garbage, (byte)'a');
        await using var phone = new FakePhone { GarbageAfterHello = garbage };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        Assert.IsType<ProtocolException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task NonJsonLine_Disconnects()
    {
        await using var phone = new FakePhone { GarbageAfterHello = "garbage\n"u8.ToArray() };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        Assert.IsType<ProtocolException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task EofMidLine_Disconnects()
    {
        await using var phone = new FakePhone { GarbageAfterHello = "{\"t\":\"wel"u8.ToArray(), CloseAfterGarbage = true };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        Assert.IsType<ProtocolException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task Goodbye_Reported()
    {
        await using var phone = new FakePhone { Token = PhoneToken, GoodbyeAfterStatus = true };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var events = await RestAsync(client);
        Assert.Equal(4, events.Count);
        Assert.Equal(new ControlEvent.Welcomed(true), events[0]);
        Assert.IsType<ControlEvent.StatusUpdate>(events[1]);
        Assert.IsType<ControlEvent.Goodbye>(events[2]);
        Assert.Equal(new ControlEvent.Disconnected(null), events[3]);
    }

    [Fact]
    public async Task OpenFails_DisconnectedWithThatError()
    {
        var failure = new IOException("no route");
        await using var client = new ControlClient(_ => Task.FromException<Stream>(failure),
            new ControlIdentity(ClientId, PcName, null), "iPhone", new FakeTimeProvider());

        await client.StartAsync(CancellationToken.None);

        Assert.Same(failure, await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task Dispose_EndsWithOneDisconnectedAndClosesConnection()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        var client = Client(phone, PhoneToken);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));

        await client.DisposeAsync();
        await client.DisposeAsync(); // a second dispose adds nothing

        await phone.WaitClosedAsync();
        var events = await RestAsync(client);
        Assert.Equal(new ControlEvent.Disconnected(null), events[^1]);
        Assert.Single(events, e => e is ControlEvent.Disconnected);
    }

    [Fact]
    public async Task Dispose_WhileOpening_CancelsTheOpen()
    {
        var opening = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var client = new ControlClient(async ct =>
        {
            opening.SetResult();
            try { await Task.Delay(Timeout.Infinite, ct); }
            catch (OperationCanceledException) { cancelled.SetResult(); throw; }
            throw new InvalidOperationException("unreachable");
        }, new ControlIdentity(ClientId, PcName, null), "iPhone", new FakeTimeProvider());

        var start = client.StartAsync(CancellationToken.None);
        await opening.Task;
        await client.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        await start.WaitAsync(TimeSpan.FromSeconds(5));

        await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5)); // the open saw the cancellation
        var events = await RestAsync(client);
        Assert.Equal(new ControlEvent.Disconnected(null), Assert.Single(events));
    }

    [Fact]
    public async Task Dispose_WhileOpening_StreamThatAppearsLaterIsDisposed()
    {
        var opening = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stream = new GatedStream(new MemoryStream(), _ => false);
        var client = new ControlClient(async _ =>
        {
            opening.SetResult();
            await gate.Task; // ignores cancellation
            return stream;
        }, new ControlIdentity(ClientId, PcName, null), "iPhone", new FakeTimeProvider());

        var start = client.StartAsync(CancellationToken.None);
        await opening.Task;
        await client.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        await start.WaitAsync(TimeSpan.FromSeconds(5));
        gate.SetResult();

        await WaitUntilAsync(() => stream.IsDisposed);
        Assert.Equal(new ControlEvent.Disconnected(null), Assert.Single(await RestAsync(client)));
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("condition never held");
            await Task.Delay(10);
        }
    }
}
