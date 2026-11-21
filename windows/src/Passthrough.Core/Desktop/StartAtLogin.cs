namespace Passthrough.Core.Desktop;

/// <summary>
/// The value of the Start at login entry (<c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>, value
/// <c>Passthrough</c>): the quoted path of the running exe. The App reads and writes the registry; the rules are here.
/// </summary>
public static class StartAtLogin
{
    /// <summary>The value to store: the exe's path in quotes (it may contain spaces).</summary>
    public static string Command(string exePath) => $"\"{exePath}\"";

    /// <summary>Whether a stored value starts this exe (quotes and surrounding spaces ignored; Windows paths ignore case).</summary>
    public static bool PointsAt(string? value, string? exePath)
    {
        if (string.IsNullOrWhiteSpace(value) || string.IsNullOrEmpty(exePath)) return false;
        var path = value.Trim();
        if (path.Length >= 2 && path[0] == '"' && path[^1] == '"') path = path[1..^1];
        return string.Equals(path, exePath, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The value to write at launch so an enabled entry starts this exe (the app was moved or rebuilt elsewhere), or null
    /// to leave it: not enabled, already right, or this exe's path unknown.
    /// </summary>
    public static string? Repair(string? value, string? exePath) =>
        value is null || string.IsNullOrEmpty(exePath) || PointsAt(value, exePath) ? null : Command(exePath);
}
