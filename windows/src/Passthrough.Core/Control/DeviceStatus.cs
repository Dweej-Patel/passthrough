namespace Passthrough.Core.Control;

/// <summary>The phone's live facts from a <c>status</c> message (protocol/README.md, device facts).</summary>
public sealed record DeviceStatus(string? DeviceName, string? Radio, string? Carrier, double? Battery, string? Hosting, bool? Ipv6, string? InternetFrom);
