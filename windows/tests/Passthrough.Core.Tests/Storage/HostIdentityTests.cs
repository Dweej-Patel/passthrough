using Passthrough.Core.Storage;
using Xunit;

namespace Passthrough.Core.Tests.Storage;

public class HostIdentityTests
{
    [Fact]
    public void ClientId_CreatedOnceAndReused()
    {
        var settings = new MemorySettingsStore();

        var id = HostIdentity.ClientId(settings);

        Assert.True(Guid.TryParse(id, out _));
        Assert.Equal(id.ToUpperInvariant(), id);
        Assert.Equal(id, settings.Get("clientID"));
        Assert.Equal(id, HostIdentity.ClientId(settings));

        settings.Set("clientID", "6F9619FF-8B86-D011-B42D-00C04FC964FF");
        Assert.Equal("6F9619FF-8B86-D011-B42D-00C04FC964FF", HostIdentity.ClientId(settings));
    }

    [Fact]
    public void MemoryStores_GetSetDelete()
    {
        var secrets = new MemorySecretStore();
        Assert.Null(secrets.Get("token.android.R58M123"));
        secrets.Set("token.android.R58M123", "t");
        Assert.Equal("t", secrets.Get("token.android.R58M123"));
        secrets.Delete("token.android.R58M123");
        secrets.Delete("token.android.R58M123");
        Assert.Null(secrets.Get("token.android.R58M123"));

        var settings = new MemorySettingsStore();
        Assert.Null(settings.Get("androidEnabled"));
        settings.Set("androidEnabled", "false");
        Assert.Equal("false", settings.Get("androidEnabled"));
    }
}
