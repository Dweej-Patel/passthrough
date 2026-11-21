using Passthrough.Core.Shell.Access;
using Passthrough.Core.Storage;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Remote;
using Passthrough.Windows.Shell;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>Remote access as the tray app runs it: the switch, the PC's iroh identity, grants and revokes.</summary>
public sealed class RemoteAccessTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"RemoteAccessTests-{Guid.NewGuid():N}");
    private readonly MemorySettingsStore _settings = new();
    private readonly MemorySecretStore _secrets = new();
    private readonly List<RemoteAccess> _made = [];

    public void Dispose()
    {
        _made.ForEach(r => r.Dispose());
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private RemoteAccess Make()
    {
        // Relays off: tests never reach n0's servers.
        _settings.Set(RemoteAccess.RelayUrlSetting, "");
        var remote = new RemoteAccess(_settings, _secrets, _directory, "Office-PC", relayOverride: IrohRelay.None);
        _made.Add(remote);
        return remote;
    }

    [Fact]
    public async Task OnItGrantsItsIrohIdentity_OffItGrantsNothing()
    {
        var remote = Make();
        Assert.Null(await remote.GrantContentsAsync());
        await remote.SetEnabledAsync(true);
        if (UserEnvironment.IsElevated())
        {
            // CI's runners are elevated: then it refuses, and says why.
            Assert.Equal(RemoteAccessState.Unavailable, remote.State);
            Assert.Contains("administrator", remote.Problem);
            Assert.Null(await remote.GrantContentsAsync());
            return;
        }
        Assert.Equal(RemoteAccessState.On, remote.State);
        var grant = await remote.GrantContentsAsync();
        Assert.NotNull(grant);
        Assert.Equal(GrantContents.NoListenerPin, grant.CertSHA256);
        Assert.Equal("Office-PC", grant.HostName);
        Assert.Equal(IrohEndpoint.IdOf(Convert.FromBase64String(_secrets.Get(RemoteAccess.SecretKeySlot)!)), grant.IrohId);

        // The same identity after a restart: phones keep dialling the same id.
        await remote.SetEnabledAsync(false);
        Assert.Null(await remote.GrantContentsAsync());
        var again = Make();
        await again.StartIfEnabledAsync();
        Assert.Equal(RemoteAccessState.Off, again.State);
        await again.SetEnabledAsync(true);
        Assert.Equal(grant.IrohId, (await again.GrantContentsAsync())?.IrohId);
    }

    [Fact]
    public void TheHistoryFolderIsOnlyThisAccounts_AndRetentionIsAChoice()
    {
        var remote = Make();
        Assert.True(PrivateFolder.OnlyMine(_directory));
        Assert.Equal(RemoteAccess.DefaultHistoryDays, remote.HistoryDays);
        remote.HistoryDays = 0;
        Assert.Equal(0, Make().HistoryDays);
        Assert.Throws<ArgumentOutOfRangeException>(() => remote.HistoryDays = 3);

        // A finished session older than a week goes; with Forever, it stays.
        var old = remote.Transcripts.Begin("old", "pwsh", "iPhone", 80, 24, DateTimeOffset.UtcNow.AddDays(-10));
        old.Finish(0, DateTimeOffset.UtcNow.AddDays(-9));
        Assert.Equal(0, remote.PruneHistory());
        remote.HistoryDays = 7;
        Assert.Empty(remote.Transcripts.Entries());
        remote.Transcripts.Begin("done", "pwsh", "iPhone", 80, 24, DateTimeOffset.UtcNow).Finish(0, DateTimeOffset.UtcNow);
        remote.DeleteHistory();
        Assert.Empty(remote.Transcripts.Entries());
    }

    [Fact]
    public async Task RelaysAreHttpsOnly_AndATokenIsKeptApart()
    {
        var remote = Make();
        foreach (var bad in new[] { "http://relay.example", "relay.example", "https://relay.example/?token=x", "https://user:pw@relay.example", "" })
            Assert.Null(RemoteAccess.ValidRelayUrl(bad));
        Assert.Equal("https://relay.example/", RemoteAccess.ValidRelayUrl(" https://relay.example "));
        await remote.SetRelayAsync("https://relay.example", "s3cret");
        Assert.Equal("https://relay.example/", remote.RelayUrl);
        Assert.True(remote.HasRelayToken);
        Assert.DoesNotContain("s3cret", _settings.Get(RemoteAccess.RelayUrlSetting) ?? "");
        await remote.SetRelayAsync("https://other.example", null);
        Assert.True(remote.HasRelayToken, "null keeps the token");
        await remote.SetRelayAsync(null, null);
        Assert.Null(remote.RelayUrl);
        Assert.False(remote.HasRelayToken, "n0's relays need none");
        await Assert.ThrowsAsync<ArgumentException>(() => remote.SetRelayAsync("http://x", null));
    }

    [Fact]
    public async Task ResettingTheIdentityTakesEveryPhonesAccessAway()
    {
        var remote = Make();
        await remote.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Enumerable.Repeat((byte)1, 32).ToArray());
        await remote.SetEnabledAsync(true);
        var before = (await remote.GrantContentsAsync())?.IrohId;
        await remote.ResetIdentityAsync();
        Assert.Empty(remote.Access.Phones);
        if (before is not null) Assert.NotEqual(before, (await remote.GrantContentsAsync())?.IrohId);
    }

    [Fact]
    public async Task AConfirmedKeyIsKept_AndForgettingThePairingTakesItAway()
    {
        var remote = Make();
        var changes = 0;
        remote.PhonesChanged += () => Interlocked.Increment(ref changes);
        Assert.True(await remote.AddKeyAsync("phone-a", "iPhone", "token.iphone.A", Enumerable.Repeat((byte)1, 32).ToArray()));
        Assert.False(await remote.AddKeyAsync("phone-a", "iPhone", "token.android.B", Enumerable.Repeat((byte)2, 32).ToArray()));
        Assert.Single(remote.Access.Phones);
        await remote.RevokeSlotAsync("token.iphone.A");
        Assert.Empty(remote.Access.Phones);
        Assert.True(changes >= 2);
    }
}
