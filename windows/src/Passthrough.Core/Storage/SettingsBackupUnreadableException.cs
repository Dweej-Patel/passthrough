namespace Passthrough.Core.Storage;

/// <summary>
/// <c>settings.json</c> is missing and its <c>.bad</c> copy (which holds the client id the phones know this PC by) exists
/// but could not be read, even after a few tries. Starting empty would mint a new client id and silently unpair every
/// phone, so startup fails with this instead; its message is for the user.
/// </summary>
public sealed class SettingsBackupUnreadableException(string path, Exception inner)
    : IOException($"Passthrough couldn't read its saved settings backup at {path}. Close anything using it and start Passthrough again.", inner)
{
    /// <summary>The <c>.bad</c> file that could not be read.</summary>
    public string Path { get; } = path;
}
