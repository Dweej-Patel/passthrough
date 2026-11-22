using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>
/// What a host says about itself in <c>host</c>, sent right after <c>ready</c> (after <c>macInfo</c>)
/// and again whenever it changes (protocol/README.md, "The host"); port of Host.swift. Every field
/// is optional; a host that sends no <c>host</c> is a Mac from before it.
/// </summary>
public sealed record HostInfo
{
    public const string KindMac = "mac", KindWindows = "windows";
    public const string ScreenVideo = "video", ScreenRfb = "rfb", ScreenRdp = "rdp";
    public const int MaxShells = 32;
    /// <summary>Longest <c>host</c> line either side sends or accepts.</summary>
    public const int MaxLineBytes = 16_384;
    /// <summary>With <c>console</c> <c>active</c> and less idle than this, someone is using the host.</summary>
    public const int InUseIdleSeconds = 120;
    public static readonly IReadOnlyList<string> ConsoleStates = ["active", "locked", "signedOut", "otherUser"];

    /// <summary><c>mac</c> or <c>windows</c>.</summary>
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    [JsonPropertyName("os")] public string? Os { get; init; }
    /// <summary>The account that granted this phone has a session on the host (locked counts).</summary>
    [JsonPropertyName("signedIn")] public bool? SignedIn { get; init; }
    /// <summary>Passthrough is running in that session, so shells can start.</summary>
    [JsonPropertyName("app")] public bool? App { get; init; }
    /// <summary><c>active</c>, <c>locked</c>, <c>signedOut</c> or <c>otherUser</c>; absent when unknown.</summary>
    [JsonPropertyName("console")] public string? Console { get; init; }
    [JsonPropertyName("idleSeconds")] public int? IdleSeconds { get; init; }
    [JsonPropertyName("shells")] public List<HostShell>? Shells { get; init; }
    /// <summary>Any of <c>video</c>, <c>rfb</c>, <c>rdp</c>.</summary>
    [JsonPropertyName("screens")] public List<string>? Screens { get; init; }
    /// <summary><c>ready</c>, or why not: <c>off</c>, <c>edition</c>, <c>account</c>, <c>service</c>, <c>exposed</c>, <c>policy</c>.</summary>
    [JsonPropertyName("rdp")] public string? Rdp { get; init; }
    [JsonPropertyName("access")] public HostAccess? Access { get; init; }
    /// <summary>This device may lock the host's screen.</summary>
    [JsonPropertyName("lock")] public bool? Lock { get; init; }
    /// <summary>The host's identity public key for computer passes.</summary>
    [JsonPropertyName("idKey")] public string? IdKey { get; init; }
    /// <summary>The name its Windows sign-in takes; sent only to a device allowed the screen.</summary>
    [JsonPropertyName("user")] public string? User { get; init; }
    /// <summary>Seconds on mains until the host sleeps; 0 for never.</summary>
    [JsonPropertyName("sleepAfter")] public int? SleepAfter { get; init; }
    /// <summary>The host's own monitor, so a viewer can leave its size and scale as they are.</summary>
    [JsonPropertyName("display")] public HostDisplay? Display { get; init; }

    /// <summary>
    /// What a client may rely on: null without a <c>kind</c>; malformed fields dropped, shells checked,
    /// at most one default, unknown <c>console</c> values dropped.
    /// </summary>
    public HostInfo? Cleaned()
    {
        if (!IsLine(Kind, 32)) return null;
        List<HostShell>? shells = null;
        if (Shells is not null)
        {
            shells = [];
            var seen = new HashSet<string>(StringComparer.Ordinal);
            bool hasDefault = false;
            foreach (var shell in Shells)
            {
                if (shells.Count == MaxShells) break;
                if (!HostShell.IsValidId(shell.Id) || !IsLine(shell.Name, 64) || !seen.Add(shell.Id)) continue;
                var kept = shell;
                if (shell.Default == true)
                {
                    if (hasDefault) kept = shell with { Default = null };
                    hasDefault = true;
                }
                shells.Add(kept);
            }
        }
        return this with
        {
            Os = IsLine(Os, 64) ? Os : null,
            Console = Console is not null && ConsoleStates.Contains(Console) ? Console : null,
            IdleSeconds = IdleSeconds is >= 0 ? IdleSeconds : null,
            SleepAfter = SleepAfter is >= 0 ? SleepAfter : null,
            Display = Display is { Width: >= 1 and <= 16384, Height: >= 1 and <= 16384, Scale: >= 100 and <= 500 } ? Display : null,
            Rdp = IsLine(Rdp, 32) ? Rdp : null,
            User = IsLine(User, 256) ? User : null,
            IdKey = IdKey is { Length: <= 512 } && IdKey.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') ? IdKey : null,
            Screens = Screens?.Where(s => IsLine(s, 16)).Take(8).ToList(),
            Shells = shells,
        };
    }

    /// <summary>
    /// One line of 1 to <paramref name="max"/> UTF-16 units, with no control, format (bidi overrides, zero-width) or
    /// line and paragraph separator characters, as in Swift and Kotlin.
    /// </summary>
    internal static bool IsLine(string? text, int max) =>
        text is { Length: > 0 } && text.Length <= max && !text.Any(c => char.GetUnicodeCategory(c) is
            System.Globalization.UnicodeCategory.Control or System.Globalization.UnicodeCategory.Format
            or System.Globalization.UnicodeCategory.LineSeparator or System.Globalization.UnicodeCategory.ParagraphSeparator);
}

/// <summary>
/// The host's own monitor (<see cref="HostInfo.Display"/>): pixels, and the scale in percent. A viewer that keeps a
/// Remote Desktop session at this scale changes no DPI when the person goes back to the PC.
/// </summary>
public sealed record HostDisplay
{
    [JsonPropertyName("width")] public int Width { get; init; }
    [JsonPropertyName("height")] public int Height { get; init; }
    [JsonPropertyName("scale")] public int Scale { get; init; }
}
