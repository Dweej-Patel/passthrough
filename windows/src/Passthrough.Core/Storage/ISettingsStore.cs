namespace Passthrough.Core.Storage;

/// <summary>
/// Small persisted settings, as strings. Keys: <c>"clientID"</c> (see <see cref="HostIdentity"/>) and
/// <c>"androidEnabled"</c> (<c>"true"</c> or <c>"false"</c>; absent means true).
/// </summary>
public interface ISettingsStore
{
    /// <summary>The value for <paramref name="key"/>, or null when it was never set.</summary>
    string? Get(string key);

    void Set(string key, string value);
}
