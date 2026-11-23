using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>A shell a host offers (<see cref="HostInfo.Shells"/>); port of Host.swift.</summary>
public sealed record HostShell
{
    /// <summary>The id a Mac gives its login shell.</summary>
    public const string LoginId = "login";

    /// <summary>Stable id, sent back in <c>open</c>'s <c>shell</c>: <c>pwsh</c>, <c>cmd</c>, <c>wsl:Ubuntu</c>.</summary>
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    /// <summary>What to show: "PowerShell", "Ubuntu".</summary>
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    /// <summary>The one a plain <c>open</c> starts.</summary>
    [JsonPropertyName("default")] public bool? Default { get; init; }

    /// <summary>1 to 80 characters: a letter or digit, then letters, digits, <c>:</c>, <c>.</c>, <c>_</c> or <c>-</c>.</summary>
    public static bool IsValidId(string? id)
    {
        if (id is null || id.Length is < 1 or > 80 || !IsAsciiAlphanumeric(id[0])) return false;
        foreach (char c in id)
            if (!IsAsciiAlphanumeric(c) && c is not (':' or '.' or '_' or '-')) return false;
        return true;
    }

    private static bool IsAsciiAlphanumeric(char c) => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z';
}
