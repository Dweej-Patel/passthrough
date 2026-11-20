namespace Passthrough.Core.Storage;

/// <summary>
/// The name each paired phone last gave itself, kept in the settings beside the pairing (key <c>name.&lt;slot&gt;</c>), so a
/// phone that is not connected, or not attached, can still be named.
/// </summary>
public static class DeviceNames
{
    public static string Key(string slot) => "name." + slot;

    /// <summary>The saved name, or null when there is none.</summary>
    public static string? Get(ISettingsStore settings, string slot) => settings.Get(Key(slot)) is { Length: > 0 } name ? name : null;
}
