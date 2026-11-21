using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>A live shell session as the host lists it; times are Unix seconds. Port of ShellProtocol.swift.</summary>
public sealed record ShellSessionInfo
{
    /// <summary><c>origin</c> of a session started in a terminal window on the host.</summary>
    public const string OriginHost = "mac";

    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("startedAt")] public double StartedAt { get; init; }
    [JsonPropertyName("lastOutputAt")] public double LastOutputAt { get; init; }
    [JsonPropertyName("running")] public bool Running { get; init; }
    [JsonPropertyName("exitStatus")] public int? ExitStatus { get; init; }
    /// <summary>The question a running session went quiet on, as the host reads its screen; absent when it isn't waiting.</summary>
    [JsonPropertyName("waiting")] public string? Waiting { get; init; }
    /// <summary><see cref="OriginHost"/> for a session started in a terminal window on the host; absent for one a phone opened.</summary>
    [JsonPropertyName("origin")] public string? Origin { get; init; }
    /// <summary>The colours of the terminal window on the host that shows the session, when it said.</summary>
    [JsonPropertyName("theme")] public ShellTheme? Theme { get; init; }
    /// <summary>What the program in it says it is doing (OSC 7501), when it says.</summary>
    [JsonPropertyName("status")] public ShellStatus? Status { get; init; }
}
