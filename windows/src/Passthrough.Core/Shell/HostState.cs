using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>
/// How the host is doing, sent to a phone in <c>macState</c>; port of <c>MacState</c> in
/// ShellProtocol.swift (the wire keeps the Mac's name). Every field is optional: a host leaves
/// out what it doesn't know or doesn't have.
/// </summary>
public sealed record HostState
{
    public const string VpnOff = "off", VpnConnecting = "connecting", VpnOn = "on", VpnFailed = "failed";
    public const string StoppedBattery = "battery", StoppedHeat = "heat";

    [JsonPropertyName("awake")] public bool? Awake { get; init; }
    /// <summary>Why Keep awake turned itself off or refused to turn on: <c>battery</c> or <c>heat</c>.</summary>
    [JsonPropertyName("awakeStopped")] public string? AwakeStopped { get; init; }
    /// <summary>0 to 1; absent without a battery.</summary>
    [JsonPropertyName("battery")] public double? Battery { get; init; }
    [JsonPropertyName("charging")] public bool? Charging { get; init; }
    [JsonPropertyName("minutesLeft")] public int? MinutesLeft { get; init; }
    [JsonPropertyName("batteryFloor")] public double? BatteryFloor { get; init; }
    [JsonPropertyName("hot")] public bool? Hot { get; init; }
    /// <summary><c>off</c>, <c>connecting</c>, <c>on</c> or <c>failed</c>; absent with no VPN set up.</summary>
    [JsonPropertyName("vpn")] public string? Vpn { get; init; }
    [JsonPropertyName("vpnName")] public string? VpnName { get; init; }
    [JsonPropertyName("killSwitch")] public bool? KillSwitch { get; init; }
    /// <summary>This phone may send <c>setAwake</c>, <c>setVPN</c> and <c>lock</c>.</summary>
    [JsonPropertyName("control")] public bool? Control { get; init; }
    [JsonPropertyName("internet")] public bool? Internet { get; init; }
    /// <summary>The host's screen is locked; absent when it can't tell.</summary>
    [JsonPropertyName("locked")] public bool? Locked { get; init; }
}
