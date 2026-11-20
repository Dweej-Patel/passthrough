using System.Text.RegularExpressions;

namespace Passthrough.Core.Transport;

/// <summary>
/// Finds adb. Touches nothing itself: environment and file checks are injected. Every <see cref="Find"/> reads the
/// environment again, so platform-tools installed while Passthrough runs are found at the next search.
/// </summary>
/// <param name="sources">
/// Where variables are read. <c>ANDROID_HOME</c>, <c>ANDROID_SDK_ROOT</c> and <c>LOCALAPPDATA</c> come from the user's
/// stored environment, else the machine's, else the process's. PATH is searched as Windows builds it for a new process
/// (the machine's entries, then the user's), then the process's own entries. <c>%NAME%</c> references in a value
/// (stored PATH entries keep them) are expanded the same way; an unknown name is left as written.
/// </param>
/// <param name="fileExists">Tells whether a file exists.</param>
/// <param name="pathSeparator">Separates PATH entries (";" on Windows).</param>
/// <param name="exeName">The binary name ("adb.exe" on Windows).</param>
/// <param name="directorySeparator">Joins directory and file names in candidates; passed in so Windows paths are testable anywhere.</param>
public sealed partial class AdbLocator(
    EnvironmentSources sources,
    Func<string, bool> fileExists,
    string pathSeparator,
    string exeName,
    char directorySeparator = '\\')
{
    /// <summary>Reads only <paramref name="env"/> (the process's environment, or a test's).</summary>
    public AdbLocator(Func<string, string?> env, Func<string, bool> fileExists, string pathSeparator, string exeName, char directorySeparator = '\\')
        : this(new EnvironmentSources(env), fileExists, pathSeparator, exeName, directorySeparator) { }

    public string? Find()
    {
        var dirs = new List<string>();
        AddSdk(dirs, Get("ANDROID_HOME"));
        AddSdk(dirs, Get("ANDROID_SDK_ROOT"));
        var local = Get("LOCALAPPDATA");
        if (!string.IsNullOrEmpty(local))
            dirs.Add(Join(local, "Android", "Sdk", "platform-tools"));
        foreach (var path in new[] { ReadStored(sources.Machine, "PATH"), ReadStored(sources.User, "PATH"), sources.Process("PATH") })
        {
            foreach (var entry in (Expand(path) ?? "").Split(pathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                if (!dirs.Contains(entry, StringComparer.OrdinalIgnoreCase)) dirs.Add(entry);
        }

        foreach (var dir in dirs)
        {
            var candidate = Join(dir, exeName);
            if (fileExists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>A variable's current value: the user's stored one, else the machine's, else the process's; expanded.</summary>
    private string? Get(string name) => Expand(Lookup(name));

    private string? Lookup(string name) =>
        NonEmpty(ReadStored(sources.User, name)) ?? NonEmpty(ReadStored(sources.Machine, name)) ?? NonEmpty(sources.Process(name));

    private static string? NonEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;

    /// <summary>A stored environment that cannot be read counts as unset (the process's own is the baseline and is read plainly).</summary>
    private static string? ReadStored(Func<string, string?>? source, string name)
    {
        if (source is null) return null;
        try { return source(name); }
        catch (Exception) { return null; }
    }

    /// <summary>Expands <c>%NAME%</c> once (not recursively), as Windows does for a stored REG_EXPAND_SZ value.</summary>
    private string? Expand(string? value) =>
        value is null || !value.Contains('%')
            ? value
            : Reference().Replace(value, m => Lookup(m.Groups[1].Value) ?? m.Value);

    [GeneratedRegex("%([^%;]+)%")]
    private static partial Regex Reference();

    private void AddSdk(List<string> dirs, string? root)
    {
        if (!string.IsNullOrEmpty(root)) dirs.Add(Join(root, "platform-tools"));
    }

    private string Join(params string[] parts) =>
        string.Join(directorySeparator, parts.Select((p, i) => i == 0 ? p.TrimEnd(directorySeparator) : p));
}
