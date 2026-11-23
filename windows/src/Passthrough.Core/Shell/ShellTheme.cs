using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>A terminal window's colours, each <c>#rrggbb</c>; port of TerminalColors.swift's <c>ShellTheme</c>.</summary>
public sealed record ShellTheme
{
    [JsonPropertyName("foreground")] public string? Foreground { get; init; }
    [JsonPropertyName("background")] public string? Background { get; init; }
    /// <summary>The 16 ANSI colours, in order; absent unless all 16 are known.</summary>
    [JsonPropertyName("palette")] public List<string>? Palette { get; init; }
}
