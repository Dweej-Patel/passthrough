using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Control;

public class ControlClientTests
{
    private const string ClientId = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    private const string PcName = "TEST-PC";
    private const string PhoneToken = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    private static ControlClient Client(FakePhone phone, string? token, TimeProvider? time = null) =>
        new(phone.Open, new ControlIdentity(ClientId, PcName, token), "iPhone", time ?? new FakeTimeProvider());

    /// <summary>A client whose reads go through <paramref name="tap"/>, so a test can wait for it to handle what the phone sent.</summary>
    private static ControlClient TappedClient(FakePhone phone, string? token, TimeProvider time, ReadTap tap) =>
        new(tap.Wrap(phone.Open), new ControlIdentity(ClientId, PcName, token), "iPhone", time);

    /// <summary>Waits until the client has handled every line the phone has sent so far.</summary>
    private static Task HandledAllSentAsync(FakePhone phone, ReadTap tap) => WaitUntilAsync(() => tap.LinesHandled >= phone.LinesSent);

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
        await using var phone = new FakePhone { IssuedToken = "fresh-token-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("042917");

        Assert.Equal(new ControlEvent.PairedWith("fresh-token-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));
        var pair = Assert.Single(phone.Received, m => m.T == ControlEnvelope.Pair);
        Assert.Equal(("042917", ClientId, PcName), (pair.Code, pair.ClientID, pair.Name));
    }

    [Fact]
    public async Task SubmitCode_SaysWhetherTheCodeWasTaken()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var phone = new FakePhone { WelcomeGate = gate.Task };
        var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.True(await client.SubmitCodeAsync("042917")); // held for the welcome
        await client.DisposeAsync();
        gate.SetResult();

        Assert.False(await client.SubmitCodeAsync("042917")); // closed: not taken
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
    public async Task UnsolicitedPaired_NoPairSubmitted_Ignored()
    {
        // The phone plants a paired right behind its welcome, then closes: by the time the close is reported the
        // planted paired has been read, and no pair was ever submitted.
        await using var phone = new FakePhone { UnsolicitedPairedToken = "planted-token-PPPPPPPPPPPPPPPPPPPPPPPPPPPPP" };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        Assert.Equal([new ControlEvent.Disconnected(null)], await RestAsync(client));
    }

    [Fact]
    public async Task ErrorWithNoPairingInFlight_Ignored()
    {
        // An error answers a pair; with none out, it is not a pairing failure (it used to read as "That code didn't match").
        await using var phone = new FakePhone { ErrorAfterWelcome = PairingFailure.BadCode.ToWire() };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        Assert.Equal([new ControlEvent.Disconnected(null)], await RestAsync(client));
    }

    [Fact]
    public async Task NotAuthenticatedAfterAuth_FailsWithNotAuthenticated()
    {
        await using var phone = new FakePhone { Token = PhoneToken, RejectsAuth = true };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.NotAuthenticated, error.Kind);
        Assert.Equal(
            "The iPhone on the cable did not accept this PC's pairing. If it is yours, use Forget Pairing in Settings and pair again.",
            error.Message);
    }

    [Fact]
    public async Task PairedWithoutToken_DisconnectsWithProtocolError()
    {
        await using var phone = new FakePhone { PairedWithoutToken = true };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("042917");

        var events = await RestAsync(client);
        var last = Assert.IsType<ControlEvent.Disconnected>(Assert.Single(events));
        Assert.Equal("The phone sent a malformed pairing token.", Assert.IsType<ProtocolException>(last.Error).Message);
    }

    [Fact]
    public void Records_NeverPrintTheToken()
    {
        Assert.DoesNotContain(PhoneToken, new ControlIdentity(ClientId, PcName, PhoneToken).ToString());
        Assert.DoesNotContain(PhoneToken, new ControlEvent.PairedWith(PhoneToken).ToString());
        Assert.Contains(ClientId, new ControlIdentity(ClientId, PcName, PhoneToken).ToString());
    }

    [Fact]
    public async Task ImmediatePairedAnswer_AlwaysAccepted()
    {
        // The fake answers pair the moment it reads it: the answer must never be lost to a race with the writer.
        for (var i = 0; i < 50; i++)
        {
            await using var phone = new FakePhone { IssuedToken = "real-token-RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR" };
            await using var client = Client(phone, token: null);

            await client.StartAsync(CancellationToken.None);
            Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
            await client.SubmitCodeAsync("042917");

            Assert.Equal(new ControlEvent.PairedWith("real-token-RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR"), await NextAsync(client));
        }
    }

    [Fact]
    public async Task PairedAfterError_Ignored()
    {
        // A wrong code is answered bad_code, then a paired nobody asked for, then the phone closes.
        await using var phone = new FakePhone { PairedAfterErrorToken = "planted-token-PPPPPPPPPPPPPPPPPPPPPPPPPPPPP" };
        await using var client = Client(phone, token: null);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("000000");

        Assert.Equal(new ControlEvent.PairingFailed(PairingFailure.BadCode), await NextAsync(client));
        Assert.Equal([new ControlEvent.Disconnected(null)], await RestAsync(client)); // the paired before the close was ignored
    }

    [Theory]
    [InlineData("short-token")]
    [InlineData("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh+")] // 43 characters, but '+' is not URL-safe
    public async Task MalformedPairedToken_DisconnectsWithProtocolError_SendsNothingMore(string token)
    {
        var time = new FakeTimeProvider();
        await using var phone = new FakePhone { IssuedToken = token };
        await using var client = Client(phone, token: null, time);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await client.SubmitCodeAsync("042917");

        var events = await RestAsync(client);
        Assert.DoesNotContain(events, e => e is ControlEvent.PairedWith or ControlEvent.StatusUpdate);
        var last = Assert.IsType<ControlEvent.Disconnected>(Assert.Single(events));
        var error = Assert.IsType<ProtocolException>(last.Error);
        Assert.Equal("The phone sent a malformed pairing token.", error.Message);
        time.Advance(ProtocolConstants.PingInterval * 3);
        await phone.WaitClosedAsync();
        Assert.Equal(new[] { ControlEnvelope.Hello, ControlEnvelope.Pair }, phone.Received.Select(m => m.T));
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
    public async Task Silent_PingsEveryFiveSeconds_DisconnectsAtExactlyTwenty()
    {
        // protocol/README.md: "Heartbeat every 5 s; the Mac gives up after 20 s of silence." Checked by behaviour
        // against the README's numbers, not against the constants.
        var time = new FakeTimeProvider();
        await using var phone = new FakePhone { Token = PhoneToken, SilentAfterStatus = true };
        await using var client = Client(phone, PhoneToken, time);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));
        Assert.Equal([TimeSpan.FromSeconds(5)], time.DueIn());

        time.Advance(TimeSpan.FromSeconds(20) - TimeSpan.FromMilliseconds(1));
        Assert.False(client.Events.TryRead(out _)); // the beats ran inside Advance: still connected at 19.999 s
        await WaitUntilAsync(() => phone.Received.Count(m => m.T == ControlEnvelope.Ping) == 3); // at 5, 10 and 15 s
        time.Advance(TimeSpan.FromMilliseconds(1));

        Assert.IsType<TimeoutException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task OnlyUnknownMessages_DisconnectsAfter20Seconds()
    {
        var time = new FakeTimeProvider();
        var tap = new ReadTap();
        await using var phone = new FakePhone { Token = PhoneToken, ChattersInsteadOfPong = true };
        await using var client = TappedClient(phone, PhoneToken, time, tap);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));

        // Each ping is answered with a message of an unknown type, which is not an answer. The client handles each
        // one before the clock moves on, so a client that wrongly counted it would have reset its silence by then.
        for (var i = 1; i <= 3; i++)
        {
            time.Advance(TimeSpan.FromSeconds(5));
            await WaitUntilAsync(() => phone.Transcript.Count(l => l == "sent chatter") >= i);
            await HandledAllSentAsync(phone, tap);
        }
        time.Advance(TimeSpan.FromSeconds(5));

        Assert.IsType<TimeoutException>(await DisconnectErrorAsync(client));
    }

    [Fact]
    public async Task Answering_StaysConnectedPast20Seconds()
    {
        var time = new FakeTimeProvider();
        var tap = new ReadTap();
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var client = TappedClient(phone, PhoneToken, time, tap);

        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.IsType<ControlEvent.StatusUpdate>(await NextAsync(client));

        // Each step lets a ping go out and the client handle its pong before the clock moves on.
        for (var i = 0; i < 6; i++)
        {
            var pongs = phone.Transcript.Count(l => l == "sent pong");
            time.Advance(TimeSpan.FromSeconds(5));
            await WaitUntilAsync(() => phone.Transcript.Count(l => l == "sent pong") > pongs);
            await HandledAllSentAsync(phone, tap);
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

    private static byte[] Lines(params string[] lines) => System.Text.Encoding.UTF8.GetBytes(string.Concat(lines.Select(l => l + "\n")));

    private static readonly string AnyNonce = Convert.ToBase64String(new byte[32]);

    private static string UnpairedWelcome(int version = ProtocolConstants.Version) =>
        $"{{\"t\":\"welcome\",\"protocolVersion\":{version},\"paired\":false,\"nonce\":\"{AnyNonce}\",\"deviceName\":\"Phone\"}}";

    private const string StatusLine = "{\"t\":\"status\",\"deviceName\":\"Phone\",\"hosting\":\"foreground\",\"rxBytes\":1,\"txBytes\":2,\"activeConnections\":3}";

    [Fact]
    public async Task StatusAndGoodbye_BeforeTheProofs_AreIgnored()
    {
        var tap = new ReadTap();
        string[] script = [StatusLine, "{\"t\":\"goodbye\"}", UnpairedWelcome(), StatusLine, "{\"t\":\"goodbye\"}"];
        await using var phone = new FakePhone { GarbageAfterHello = Lines(script) };
        await using var client = TappedClient(phone, token: null, new FakeTimeProvider(), tap);

        await client.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => tap.LinesHandled >= script.Length);

        Assert.True(client.Events.TryRead(out var only));
        Assert.Equal(new ControlEvent.Welcomed(false), only);
        Assert.False(client.Events.TryRead(out _)); // no status, no goodbye: the channel is not authenticated
    }

    [Fact]
    public async Task SecondWelcome_IsIgnored()
    {
        var tap = new ReadTap();
        // The second welcome names another version: acted on, it would end the channel as incompatible.
        string[] script = [UnpairedWelcome(), UnpairedWelcome(version: 1)];
        await using var phone = new FakePhone { GarbageAfterHello = Lines(script) };
        await using var client = TappedClient(phone, token: null, new FakeTimeProvider(), tap);

        await client.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => tap.LinesHandled >= script.Length);

        Assert.True(client.Events.TryRead(out var only));
        Assert.Equal(new ControlEvent.Welcomed(false), only);
        Assert.False(client.Events.TryRead(out _));
    }

    [Fact]
    public async Task PairedWelcome_WithANonceThatIsNot32Bytes_FailsTheProof()
    {
        var shortNonce = Convert.ToBase64String(new byte[16]);
        var proof = Convert.ToBase64String(new byte[32]);
        await using var phone = new FakePhone
        {
            GarbageAfterHello = Lines($"{{\"t\":\"welcome\",\"protocolVersion\":2,\"paired\":true,\"nonce\":\"{shortNonce}\",\"proof\":\"{proof}\",\"deviceName\":\"Phone\"}}"),
        };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.ProofFailed, error.Kind);
    }

    [Fact]
    public async Task UnsupportedVersion_WithNoProtocolVersion_ThePhoneIsOlder()
    {
        // A phone from before version 2 says nothing of its own version.
        await using var phone = new FakePhone { GarbageAfterHello = Lines("{\"t\":\"error\",\"reason\":\"unsupported_version\"}") };
        await using var client = Client(phone, PhoneToken);

        await client.StartAsync(CancellationToken.None);

        var error = Assert.IsType<ControlException>(await DisconnectErrorAsync(client));
        Assert.Equal(ControlErrorKind.Incompatible, error.Kind);
        Assert.True(error.PhoneIsOlder);
        Assert.Equal("Passthrough on the iPhone is out of date. Update it on the iPhone, then connect again.", error.Message);
    }

    /// <summary>A connection whose every write fails, as a reset socket does; reads wait (nothing arrives) until cancelled.</summary>
    private sealed class UnwritableStream : MemoryStream
    {
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) =>
            ValueTask.FromException(new IOException("the connection was reset"));

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            return 0;
        }
    }

    [Fact]
    public async Task WriteFailure_DisconnectsWithThatError()
    {
        await using var client = new ControlClient(_ => Task.FromResult<Stream>(new UnwritableStream()), new ControlIdentity(ClientId, PcName, PhoneToken), "iPhone", new FakeTimeProvider());

        await client.StartAsync(CancellationToken.None);

        Assert.Equal("the connection was reset", Assert.IsType<IOException>(await DisconnectErrorAsync(client)).Message);
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
