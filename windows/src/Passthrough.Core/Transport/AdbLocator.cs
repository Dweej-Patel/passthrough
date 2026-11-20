namespace Passthrough.Core.Transport;

/// <summary>Finds adb. Touches nothing itself: environment and file checks are injected.</summary>
/// <param name="env">Reads an environment variable.</param>
/// <param name="fileExists">Tells whether a file exists.</param>
/// <param name="pathSeparator">Separates PATH entries (";" on Windows).</param>
/// <param name="exeName">The binary name ("adb.exe" on Windows).</param>
/// <param name="directorySeparator">Joins directory and file names in candidates; passed in so Windows paths are testable anywhere.</param>
public sealed class AdbLocator(
    Func<string, string?> env,
    Func<string, bool> fileExists,
    string pathSeparator,
    string exeName,
    char directorySeparator = '\\')
{
    public string? Find()
    {
        var dirs = new List<string>();
        AddSdk(dirs, env("ANDROID_HOME"));
        AddSdk(dirs, env("ANDROID_SDK_ROOT"));
        var local = env("LOCALAPPDATA");
        if (!string.IsNullOrEmpty(local))
            dirs.Add(Join(local, "Android", "Sdk", "platform-tools"));
        foreach (var entry in (env("PATH") ?? "").Split(pathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            dirs.Add(entry);

        foreach (var dir in dirs)
        {
            var candidate = Join(dir, exeName);
            if (fileExists(candidate)) return candidate;
        }
        return null;
    }

    private void AddSdk(List<string> dirs, string? root)
    {
        if (!string.IsNullOrEmpty(root)) dirs.Add(Join(root, "platform-tools"));
    }

    private string Join(params string[] parts) =>
        string.Join(directorySeparator, parts.Select((p, i) => i == 0 ? p.TrimEnd(directorySeparator) : p));
}
