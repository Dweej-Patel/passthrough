using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>A past session in the host's history; times are Unix seconds. Port of ShellProtocol.swift.</summary>
public sealed record ShellHistoryEntry
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("phoneLabel")] public string PhoneLabel { get; init; } = "";
    [JsonPropertyName("startedAt")] public double StartedAt { get; init; }
    [JsonPropertyName("endedAt")] public double? EndedAt { get; init; }
    [JsonPropertyName("exitStatus")] public int? ExitStatus { get; init; }
    [JsonPropertyName("bytes")] public long Bytes { get; init; }
    /// <summary>The terminal's size when the session started (absent from older hosts).</summary>
    [JsonPropertyName("cols")] public int? Cols { get; init; }
    [JsonPropertyName("rows")] public int? Rows { get; init; }
}
