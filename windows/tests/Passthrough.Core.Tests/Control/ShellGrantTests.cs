using Passthrough.Core.Cable;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Passthrough.Core.Shell.Access;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Control;

/// <summary>Shell grants over the control channel (protocol/README.md, <c>shellGrant</c>), and what guards them.</summary>
public class ShellGrantTests
{
    private const string ClientId = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    private const string PhoneToken = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    private static readonly byte[] Key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

    private static readonly GrantContents Contents = new()
    {
        CertSHA256 = GrantContents.NoListenerPin,
        HostName = "Office-PC",
        IrohId = new string('a', 64),
        IrohRelay = "https://relay.example.com/",
        RelayToken = "relay-token-for-a-test",
    };

    private static ControlClient Client(FakePhone phone, string? token, PeerVerdict? verdict) =>
        new(phone.Open, new ControlIdentity(ClientId, "Office-PC", token), "iPhone", new FakeTimeProvider(),
            verdict is { } v ? _ => v : null);

    private static async Task<ControlEvent> NextAsync(ControlClient client)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        return await client.Events.ReadAsync(deadline.Token);
    }

    private static async Task<T> NextOfAsync<T>(ControlClient client) where T : ControlEvent
    {
        while (true)
            if (await NextAsync(client) is T t) return t;
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException();
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task Grant_AfterProofOnAGenuineChannel_SendsEveryFieldAndHearsTheAnswer()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var client = Client(phone, PhoneToken, PeerVerdict.Genuine);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.Equal(PeerVerdict.Genuine, client.Peer);

        Assert.True(client.GrantShell(Key, Contents, "grant-1"));
        var answer = await NextOfAsync<ControlEvent.ShellGranted>(client);
        Assert.Equal(new ControlEvent.ShellGranted("p-7c1e9a40", "grant-1"), answer);

        var grant = phone.Received.Single(m => m.T == ControlEnvelope.ShellGrant);
        Assert.Equal(Convert.ToBase64String(Key), grant.ShellKey);
        Assert.Equal(GrantContents.NoListenerPin, grant.CertSHA256);
        Assert.Equal(7893, grant.ShellPort);
        Assert.Empty(grant.Addresses!);
        Assert.Equal("Office-PC", grant.MacName);
        Assert.Equal((Contents.IrohId, Contents.IrohRelay, Contents.RelayToken), (grant.IrohID, grant.IrohRelay, grant.RelayToken));
        Assert.Equal(("grant-1", "windows"), (grant.GrantID, grant.HostKind));
        Assert.Equal("windows", phone.Received[0].HostKind); // hello says it too
    }

    [Theory]
    [InlineData(PeerVerdict.Unknown)]
    [InlineData(PeerVerdict.NotGenuine)]
    public async Task Grant_RefusedUnlessThePeerIsGenuine(PeerVerdict verdict)
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var client = Client(phone, PhoneToken, verdict);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.False(client.GrantShell(Key, Contents, "grant-1"));
        await WaitUntilAsync(() => client.Unwritten == 0);
        Assert.DoesNotContain(phone.Received, m => m.T == ControlEnvelope.ShellGrant);
    }

    [Fact]
    public async Task Grant_RefusedWithoutACheck_AndWhenTheCheckThrows()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var unchecked_ = Client(phone, PhoneToken, null);
        await unchecked_.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(unchecked_));
        Assert.False(unchecked_.GrantShell(Key, Contents, "grant-1"));

        await using var phone2 = new FakePhone { Token = PhoneToken };
        await using var throwing = new ControlClient(phone2.Open, new ControlIdentity(ClientId, "Office-PC", PhoneToken), "iPhone",
            new FakeTimeProvider(), _ => throw new InvalidOperationException("no table"));
        await throwing.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(throwing));
        Assert.Equal(PeerVerdict.Unknown, throwing.Peer);
        Assert.False(throwing.GrantShell(Key, Contents, "grant-1"));
    }

    [Fact]
    public async Task Grant_RefusedBeforeTheProof()
    {
        // No token here: the phone says unpaired and nothing is proved on this channel.
        await using var phone = new FakePhone();
        await using var client = Client(phone, null, PeerVerdict.Genuine);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        Assert.False(client.GrantShell(Key, Contents, "grant-1"));
    }

    [Fact]
    public async Task Grant_RefusesABadKeyOrId()
    {
        await using var phone = new FakePhone { Token = PhoneToken };
        await using var client = Client(phone, PhoneToken, PeerVerdict.Genuine);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(true), await NextAsync(client));
        Assert.False(client.GrantShell(new byte[31], Contents, "grant-1"));
        Assert.False(client.GrantShell(Key, Contents, ""));
        Assert.False(client.GrantShell(Key, Contents, new string('x', 65)));
        Assert.False(client.GrantShell(Key, Contents, new string('é', 33)), "64 UTF-8 bytes at most");
        Assert.True(client.GrantShell(Key, Contents, new string('x', 64)));
    }

    [Fact]
    public async Task Answer_WithoutAnIdOrWithAnother_IsPassedOnAsSent()
    {
        await using var phone = new FakePhone { Token = PhoneToken, GrantAnswer = FakePhone.GrantAnswerMode.NoId };
        await using var client = Client(phone, PhoneToken, PeerVerdict.Genuine);
        await client.StartAsync(CancellationToken.None);
        await NextAsync(client);
        Assert.True(client.GrantShell(Key, Contents, "grant-1"));
        Assert.Equal(new ControlEvent.ShellGranted("p-7c1e9a40", null), await NextOfAsync<ControlEvent.ShellGranted>(client));

        await using var other = new FakePhone { Token = PhoneToken, GrantAnswer = FakePhone.GrantAnswerMode.OtherId };
        await using var client2 = Client(other, PhoneToken, PeerVerdict.Genuine);
        await client2.StartAsync(CancellationToken.None);
        await NextAsync(client2);
        Assert.True(client2.GrantShell(Key, Contents, "grant-1"));
        Assert.Equal("another-grant", (await NextOfAsync<ControlEvent.ShellGranted>(client2)).GrantId);
    }

    [Fact]
    public async Task Answer_BeforeTheProof_IsIgnored()
    {
        await using var phone = new FakePhone { ShellGrantedAfterWelcome = true };
        await using var client = Client(phone, null, PeerVerdict.Genuine);
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(new ControlEvent.Welcomed(false), await NextAsync(client));
        await WaitUntilAsync(() => phone.Transcript.Contains("sent " + ControlEnvelope.ShellGranted));
        await Task.Delay(300); // the client reads it meanwhile
        await client.DisposeAsync();
        var rest = new List<ControlEvent>();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await foreach (var e in client.Events.ReadAllAsync(deadline.Token)) rest.Add(e);
        Assert.DoesNotContain(rest, e => e is ControlEvent.ShellGranted);
    }

    [Theory]
    [InlineData("p-7c1e9a40", true)]
    [InlineData("A.b_c-9", true)]
    [InlineData("", false)]
    [InlineData("has space", false)]
    [InlineData("line\nbreak", false)]
    [InlineData("‮evil", false)]
    public void PhoneIds_AreWhatThePhonesSend(string id, bool ok)
    {
        Assert.Equal(ok, ControlClient.IsPhoneId(id));
        Assert.False(ControlClient.IsPhoneId(new string('a', 65)));
    }

    [Fact]
    public void Contents_FingerprintMatchesTheMacsAndHidesTheToken()
    {
        // The Mac's contents string (MacSessionPolicy.swift), hashed so the token sits in no comparable field.
        var expected = $"64:{GrantContents.NoListenerPin}4:78939:Office-PC64:{new string('a', 64)}26:https://relay.example.com/22:relay-token-for-a-test";
        Assert.Equal(expected, Contents.ContentsString());
        Assert.Equal(64, Contents.Fingerprint.Length);
        Assert.DoesNotContain("relay-token", Contents.Fingerprint);
        Assert.DoesNotContain("relay-token", Contents.ToString());
        Assert.NotEqual(Contents.Fingerprint, (Contents with { RelayToken = null }).Fingerprint);
        Assert.Equal(Contents.Fingerprint, (Contents with { Addresses = ["192.168.1.2"] }).Fingerprint);
        Assert.Equal("1:-", new GrantContents { CertSHA256 = "x", HostName = "h" }.ContentsString()[^3..]);
    }
}
