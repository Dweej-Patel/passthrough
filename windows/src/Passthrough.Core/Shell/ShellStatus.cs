using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>
/// What a program in a session reports about itself (OSC 7501, the Program Status Protocol, which
/// Claude Code speaks), as the host sums it up. Port of <c>ShellStatus</c> in ShellProtocol.swift.
/// </summary>
public sealed record ShellStatus
{
    public const string Working = "working", Blocked = "blocked", Done = "done", Failed = "error", Idle = "idle";
    public const int MaxMessage = 300;

    /// <summary><c>working</c>, <c>blocked</c> (needs someone), <c>done</c>, <c>error</c> or <c>idle</c>.</summary>
    [JsonPropertyName("state")] public string State { get; init; } = Idle;
    /// <summary>Why it is blocked: <c>permission</c>, <c>question</c> or <c>auth</c>.</summary>
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    /// <summary>What it says, one line, at most <see cref="MaxMessage"/> characters.</summary>
    [JsonPropertyName("message")] public string? Message { get; init; }
    /// <summary>Its agents still working or blocked.</summary>
    [JsonPropertyName("agents")] public int Agents { get; init; }
    /// <summary>When it went into this state, Unix seconds.</summary>
    [JsonPropertyName("since")] public double Since { get; init; }
    /// <summary>Done or error, and someone has had the session in front of them since.</summary>
    [JsonPropertyName("seen")] public bool Seen { get; init; }
}
