using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>The host's battery at a moment, for the timeline's battery line; port of ShellProtocol.swift.</summary>
public sealed record BatterySample
{
    public const int MaxPerList = 600;
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);

    /// <summary>Unix seconds.</summary>
    [JsonPropertyName("t")] public double T { get; init; }
    /// <summary>0 to 1.</summary>
    [JsonPropertyName("level")] public double Level { get; init; }
    [JsonPropertyName("charging")] public bool? Charging { get; init; }
}
