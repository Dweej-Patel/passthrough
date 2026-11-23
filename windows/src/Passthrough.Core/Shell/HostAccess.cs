using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>What the device on this connection may do on the host (<see cref="HostInfo.Access"/>).</summary>
public sealed record HostAccess
{
    [JsonPropertyName("shell")] public bool? Shell { get; init; }
    [JsonPropertyName("screen")] public bool? Screen { get; init; }
    /// <summary>May hand access to this host on to another computer.</summary>
    [JsonPropertyName("share")] public bool? Share { get; init; }
}
