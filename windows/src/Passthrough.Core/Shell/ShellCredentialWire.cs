using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>
/// A credential to reach a host's shell as it travels in <c>screenPass</c>; the JSON form of
/// <c>ShellCredential</c> in ShellClient.swift (its <c>shellKey</c> is base64).
/// </summary>
public sealed record ShellCredentialWire
{
    [JsonPropertyName("macID")] public string MacID { get; init; } = "";
    [JsonPropertyName("macName")] public string MacName { get; init; } = "";
    /// <summary>SHA-256 of the host's certificate, lowercase hex: the only one accepted.</summary>
    [JsonPropertyName("certSHA256")] public string CertSHA256 { get; init; } = "";
    /// <summary>32 bytes, base64.</summary>
    [JsonPropertyName("shellKey")] public string ShellKey { get; init; } = "";
    [JsonPropertyName("phoneID")] public string PhoneID { get; init; } = "";
    [JsonPropertyName("port")] public ushort Port { get; init; }
    [JsonPropertyName("addresses")] public List<string> Addresses { get; init; } = [];
    [JsonPropertyName("irohID")] public string? IrohID { get; init; }
    [JsonPropertyName("irohRelay")] public string? IrohRelay { get; init; }
    [JsonPropertyName("relayToken")] public string? RelayToken { get; init; }

    /// <summary>Never shows the key, and says only whether there is a relay token.</summary>
    public override string ToString() =>
        $"ShellCredentialWire(macID: {MacID}, macName: {MacName}, phoneID: {PhoneID}, port: {Port}, addresses: [{string.Join(", ", Addresses)}], " +
        $"irohID: {IrohID ?? "none"}, irohRelay: {IrohRelay ?? "none"}, relayToken: {(RelayToken is null ? "none" : "<redacted>")})";
}
