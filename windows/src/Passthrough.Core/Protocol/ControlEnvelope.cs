using System.Text.Json;
using System.Text.Json.Serialization;

namespace Passthrough.Core.Protocol;

/// <summary>Newline-delimited JSON envelope used on the control channel. Every message has a type tag <c>t</c>.</summary>
public sealed class ControlEnvelope
{
    public const string Hello = "hello";
    public const string Welcome = "welcome";
    public const string Auth = "auth";
    public const string Pair = "pair";
    public const string Paired = "paired";
    public const string Error = "error";
    public const string Ping = "ping";
    public const string Pong = "pong";
    public const string Status = "status";
    public const string Link = "link";
    public const string Linked = "linked";
    public const string ShellGrant = "shellGrant";
    public const string ShellGranted = "shellGranted";
    public const string Goodbye = "goodbye";

    /// <summary>The longest grantID (UTF-8 bytes) a phone echoes.</summary>
    public const int MaxGrantIdLength = 64;

    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("protocolVersion")] public int? ProtocolVersion { get; set; }
    [JsonPropertyName("clientID")] public string? ClientID { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("code")] public string? Code { get; set; }
    [JsonPropertyName("token")] public string? Token { get; set; }
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("proof")] public string? Proof { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
    [JsonPropertyName("paired")] public bool? PairedFlag { get; set; }
    [JsonPropertyName("socksPort")] public int? SocksPort { get; set; }
    [JsonPropertyName("deviceName")] public string? DeviceName { get; set; }
    [JsonPropertyName("radio")] public string? Radio { get; set; }
    [JsonPropertyName("carrier")] public string? Carrier { get; set; }
    [JsonPropertyName("battery")] public double? Battery { get; set; }
    [JsonPropertyName("hosting")] public string? Hosting { get; set; }
    [JsonPropertyName("ipv6")] public bool? Ipv6 { get; set; }
    [JsonPropertyName("internetFrom")] public string? InternetFrom { get; set; }
    [JsonPropertyName("activeConnections")] public int? ActiveConnections { get; set; }
    [JsonPropertyName("rxBytes")] public long? RxBytes { get; set; }
    [JsonPropertyName("txBytes")] public long? TxBytes { get; set; }
    [JsonPropertyName("timestamp")] public double? Timestamp { get; set; }
    [JsonPropertyName("linkKey")] public string? LinkKey { get; set; }
    [JsonPropertyName("certSHA256")] public string? CertSHA256 { get; set; }
    [JsonPropertyName("phoneID")] public string? PhoneID { get; set; }
    [JsonPropertyName("network")] public string? Network { get; set; }
    [JsonPropertyName("passphrase")] public string? Passphrase { get; set; }
    [JsonPropertyName("via")] public string? Via { get; set; }
    [JsonPropertyName("shellKey")] public string? ShellKey { get; set; }
    [JsonPropertyName("shellPort")] public int? ShellPort { get; set; }
    [JsonPropertyName("addresses")] public List<string>? Addresses { get; set; }
    [JsonPropertyName("macName")] public string? MacName { get; set; }
    [JsonPropertyName("irohID")] public string? IrohID { get; set; }
    [JsonPropertyName("irohRelay")] public string? IrohRelay { get; set; }
    [JsonPropertyName("relayToken")] public string? RelayToken { get; set; }
    [JsonPropertyName("grantID")] public string? GrantID { get; set; }

    public ControlEnvelope() { }
    public ControlEnvelope(string t) { T = t; }

    /// <summary>UTF-8 JSON followed by a newline; absent fields are omitted.</summary>
    public byte[] EncodeLine()
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(this, Options);
        var line = new byte[json.Length + 1];
        json.CopyTo(line, 0);
        line[^1] = (byte)'\n';
        return line;
    }

    /// <summary>Parses one line (without its newline); unknown fields are ignored.</summary>
    public static ControlEnvelope Decode(ReadOnlySpan<byte> line)
    {
        ControlEnvelope? envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<ControlEnvelope>(line, Options);
        }
        catch (JsonException e)
        {
            throw new ProtocolException($"Not a control message: {e.Message}");
        }
        if (envelope is null || string.IsNullOrEmpty(envelope.T))
            throw new ProtocolException("Control message has no type");
        return envelope;
    }
}
