using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>
/// Something that happened on the host, for the phone's timeline; port of <c>MacEvent</c> in
/// ShellProtocol.swift. <c>title</c> and <c>detail</c> are written by the host, ready to show.
/// </summary>
public sealed record HostEvent
{
    public const int MaxPerList = 500;
    public static readonly TimeSpan Kept = TimeSpan.FromDays(7);

    /// <summary>Unix seconds.</summary>
    [JsonPropertyName("t")] public double T { get; init; }
    /// <summary><c>awake</c>, <c>vpn</c>, <c>link</c>, <c>power</c>, <c>sleep</c>, <c>shell</c>, <c>asked</c> or <c>answered</c>.</summary>
    [JsonPropertyName("kind")] public string Kind { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; init; }
    [JsonPropertyName("session")] public string? Session { get; init; }
    [JsonPropertyName("warning")] public bool? Warning { get; init; }
}
