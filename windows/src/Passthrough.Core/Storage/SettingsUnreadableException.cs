namespace Passthrough.Core.Storage;

/// <summary>
/// <c>settings.json</c> exists but could not be read, even after a few tries (another program holds it, or access is
/// denied). Starting without it would give the PC a new client id and unpair every phone, so startup fails with this;
/// its message is for the user.
/// </summary>
public sealed class SettingsUnreadableException(string path, Exception inner)
    : IOException($"Passthrough couldn't read its settings at {path}. Close anything using it and start Passthrough again.", inner)
{
    /// <summary>The settings file that could not be read.</summary>
    public string Path { get; } = path;
}
