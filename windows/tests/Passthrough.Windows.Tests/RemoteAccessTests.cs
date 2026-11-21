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
