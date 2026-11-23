namespace Passthrough.Core.Desktop;

/// <summary>
/// The value of the Start at login entry (<c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>, value
/// <c>Passthrough</c>). Without Remote access's install it is the quoted path of the running exe. Once installed it is
/// the launcher, the service's exe at the path that never changes with <c>--launch</c>, which starts whatever build is
/// installed: install folders come and go with updates, and an entry pointing into one would one day point at nothing.
/// The App reads and writes the registry; the rules are here.
/// </summary>
public static class StartAtLogin
{
    public const string LaunchVerb = "--launch";

    /// <summary>The value to store: the exe's path in quotes (it may contain spaces).</summary>
    public static string Command(string exePath) => $"\"{exePath}\"";

    /// <summary>The value that starts the installed app through <paramref name="launcher"/>.</summary>
    public static string LauncherCommand(string launcher) => $"\"{launcher}\" {LaunchVerb}";

    /// <summary>Whether a stored value starts this exe (quotes and surrounding spaces ignored; Windows paths ignore case).</summary>
    public static bool PointsAt(string? value, string? exePath)
    {
        if (string.IsNullOrWhiteSpace(value) || string.IsNullOrEmpty(exePath)) return false;
        var path = value.Trim();
        if (path.Length >= 2 && path[0] == '"' && path[^1] == '"') path = path[1..^1];
        return string.Equals(path, exePath, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Whether a stored value starts the installed app through <paramref name="launcher"/>.</summary>
    public static bool IsLauncher(string? value, string? launcher) =>
        !string.IsNullOrWhiteSpace(value) && !string.IsNullOrEmpty(launcher)
        && string.Equals(value.Trim(), LauncherCommand(launcher), StringComparison.OrdinalIgnoreCase);

    /// <summary>Whether the switch reads as on: the entry starts this exe, or (installed) the launcher.</summary>
    public static bool IsEnabled(string? value, string? exePath, string? launcher) =>
        launcher is not null ? IsLauncher(value, launcher) || PointsAt(value, exePath) : PointsAt(value, exePath);

    /// <summary>What turning the switch on writes: the launcher when installed, else this exe.</summary>
    public static string EnabledValue(string exePath, string? launcher) => launcher is not null ? LauncherCommand(launcher) : Command(exePath);

    /// <summary>
    /// The value to write at launch so an enabled entry starts the right copy, or null to leave it. Installed: an
    /// enabled entry becomes the launcher, but only when this copy is the installed one (<paramref name="isInstalledCopy"/>):
    /// a build run from anywhere else never takes the entry. Not installed: it follows this exe (moved or rebuilt).
    /// </summary>
    public static string? Repair(string? value, string? exePath, string? launcher = null, bool isInstalledCopy = false)
    {
        if (value is null || string.IsNullOrEmpty(exePath)) return null;
        if (launcher is not null)
            return isInstalledCopy && !IsLauncher(value, launcher) ? LauncherCommand(launcher) : null;
        return PointsAt(value, exePath) ? null : Command(exePath);
    }
}
