using System.Security.Cryptography;
using System.Text.Json;

namespace Passthrough.Core.Setup;

/// <summary>
/// <c>files.json</c>, written by <c>scripts/build-windows.ps1</c> beside the build: every file's path (relative,
/// backslashes), size and SHA-256. The install copies exactly these files, from bytes it hashed.
/// </summary>
public sealed record FileManifest(string Build, IReadOnlyList<FileManifest.Entry> Files)
{
    public sealed record Entry(string Path, long Size, string Sha256);

    /// <summary>The runtime a self-contained build carries; a framework-dependent one has none, and a service account couldn't use the user's .NET.</summary>
    public bool IsSelfContained => Files.Any(f => string.Equals(f.Path, "coreclr.dll", StringComparison.OrdinalIgnoreCase));

    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    private static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(this, Options);

    /// <summary>
    /// The manifest, or null when it doesn't parse or names a path that could leave the folder (absolute, a drive,
    /// <c>..</c>, a stream), or one twice.
    /// </summary>
    public static FileManifest? Decode(byte[] bytes)
    {
        FileManifest? manifest;
        try { manifest = JsonSerializer.Deserialize<FileManifest>(bytes, Options); }
        catch (JsonException) { return null; }
        if (manifest is null || string.IsNullOrWhiteSpace(manifest.Build) || manifest.Files is null || manifest.Files.Count == 0) return null;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in manifest.Files)
        {
            if (file is null || !IsSafeRelative(file.Path) || file.Size < 0 || file.Sha256 is not { Length: 64 } || !file.Sha256.All(Uri.IsHexDigit)) return null;
            if (!seen.Add(file.Path)) return null;
        }
        return manifest;
    }

    internal static bool IsSafeRelative(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > 200) return false;
        if (path.Contains('/') || path.Contains(':') || path.StartsWith('\\') || path.EndsWith('\\')) return false;
        return path.Split('\\').All(part => part.Length > 0 && part is not "." and not ".."
            && part.All(c => c >= 0x20 && c is not '<' and not '>' and not '"' and not '|' and not '?' and not '*')
            && !part.EndsWith(' ') && !part.EndsWith('.') && !IsDeviceName(part));
    }

    /// <summary>CON, NUL, COM1… (with any extension): Windows opens a device, not a file.</summary>
    private static bool IsDeviceName(string part)
    {
        var stem = part.Split('.')[0].ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
            || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsAsciiDigit(stem[3]));
    }

    /// <summary>A safe name for a folder from the build ("0.9.0+abc1234" → "0.9.0-abc1234").</summary>
    public string FolderName => new string([.. Build.Select(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' ? c : '-')]).Trim('.', '-') is { Length: > 0 } name
        ? name[..Math.Min(name.Length, 40)] : "build";
}
