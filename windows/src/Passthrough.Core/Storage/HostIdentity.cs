namespace Passthrough.Core.Storage;

/// <summary>Who this PC is to its phones.</summary>
public static class HostIdentity
{
    private const string ClientIdKey = "clientID";

    /// <summary>
    /// This PC's client id: a UUID made once and kept in <paramref name="settings"/>, so a phone recognizes the PC
    /// across launches (the Mac's <c>clientID</c>).
    /// </summary>
    public static string ClientId(ISettingsStore settings)
    {
        if (settings.Get(ClientIdKey) is { Length: > 0 } stored) return stored;
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        settings.Set(ClientIdKey, id);
        return id;
    }
}
