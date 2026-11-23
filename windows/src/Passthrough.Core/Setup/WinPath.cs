namespace Passthrough.Core.Setup;

/// <summary>Windows paths built the same on any OS (Core's tests also run on macOS, where Path uses '/').</summary>
public static class WinPath
{
    private static readonly char[] Separators = ['\\', '/'];

    public static string Join(string folder, params string[] parts) => string.Join('\\', [folder.TrimEnd(Separators), .. parts]);

    /// <summary>The last part of a path.</summary>
    public static string Name(string path)
    {
        var trimmed = path.TrimEnd(Separators);
        var i = trimmed.LastIndexOfAny(Separators);
        return i >= 0 ? trimmed[(i + 1)..] : trimmed;
    }

    /// <summary>The folder a path is in, or null at a root.</summary>
    public static string? Parent(string path)
    {
        var trimmed = path.TrimEnd(Separators);
        var i = trimmed.LastIndexOfAny(Separators);
        return i > 0 ? trimmed[..i] : null;
    }
}
