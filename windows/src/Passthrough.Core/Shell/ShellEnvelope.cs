using System.Text.Json;
using System.Text.Json.Serialization;
using Passthrough.Core.Protocol;

namespace Passthrough.Core.Shell;

/// <summary>
/// Newline-delimited JSON envelope on the shell connection; a port of <c>ShellEnvelope</c> in
/// ShellProtocol.swift. Binary fields (<c>data</c>, <c>nonce</c>, <c>mac</c>) are base64. Unknown
/// fields are ignored and absent ones are omitted; a known field of the wrong JSON type fails the
/// whole line, as it does on the phones.
/// </summary>
public sealed class ShellEnvelope
{
    public const string Hello = "hello";
    public const string MacInfo = "macInfo";
    public const string Challenge = "challenge";
    public const string Proof = "proof";
    public const string Ready = "ready";
    public const string List = "list";
    public const string Sessions = "sessions";
    public const string Open = "open";
    public const string Opened = "opened";
    public const string Attach = "attach";
    public const string Attached = "attached";
    public const string Replaying = "replaying";
    public const string Input = "input";
    public const string Resize = "resize";
    public const string Output = "output";
    public const string Close = "close";
    public const string Ended = "ended";
    public const string Detached = "detached";
    public const string History = "history";
    public const string HistoryList = "historyList";
    public const string Transcript = "transcript";
    public const string TranscriptData = "transcriptData";
    public const string Screen = "screen";
    public const string ScreenReady = "screenReady";
    public const string ScreenVideo = "screenVideo";
    public const string ScreenVideoReady = "screenVideoReady";
    public const string MacState = "macState";
    public const string SetAwake = "setAwake";
    public const string SetVpn = "setVPN";
    public const string Lock = "lock";
    public const string Viewing = "viewing";
    public const string PushRegister = "push";
    public const string PushState = "pushState";
    public const string Events = "events";
    public const string EventList = "eventList";
    public const string ScreenGrant = "screenGrant";
    public const string ScreenGranted = "screenGranted";
    public const string ScreenRevoke = "screenRevoke";
    public const string ScreenRevoked = "screenRevoked";
    public const string ScreenPass = "screenPass";
    public const string ScreenPassSaved = "screenPassSaved";
    public const string Ping = "ping";
    public const string Pong = "pong";
    public const string Error = "error";
    /// <summary>What the host is (<see cref="HostInfo"/>), after <c>macInfo</c> and whenever it changes.</summary>
    public const string Host = "host";
    /// <summary>The host is about to go away (<c>reason</c>: <c>sleeping</c>, <c>turned_off</c>, <c>shutting_down</c>).</summary>
    public const string GoingAway = "goingAway";
    /// <summary>The screen through the host's Remote Desktop: answered <c>rdpReady</c> (<c>certSHA256</c>), then raw bytes.</summary>
    public const string Rdp = "rdp";
    public const string RdpReady = "rdpReady";
    /// <summary>
    /// Clipboard sync between computers (<see cref="ClipSync.ClipSyncWire"/>), on a connection of its own while the
    /// asker views the screen: answered <c>clipSyncReady</c>, then binary messages both ways.
    /// </summary>
    public const string ClipSync = "clipSync";
    public const string ClipSyncReady = "clipSyncReady";
    /// <summary>A view of the screen on this device's other connection ended (<c>reason</c>: <c>switched_off</c>, <c>stopped</c>, <c>taken</c>).</summary>
    public const string ScreenEnded = "screenEnded";
    /// <summary>
    /// Computers (stage 7): a phone gives another of its computers access (<c>computerGrant</c>, answered
    /// <c>computerGranted</c>), hands it over (<c>computerPass</c>, answered <c>computerPassSaved</c>), or takes back any
    /// computer it gave access to, at any time (<c>computerRevoke</c>, answered <c>computerRevoked</c>; its connections
    /// and sessions end).
    /// </summary>
    public const string ComputerGrant = "computerGrant", ComputerGranted = "computerGranted", ComputerPass = "computerPass",
        ComputerPassSaved = "computerPassSaved", ComputerRevoke = "computerRevoke", ComputerRevoked = "computerRevoked";
    /// <summary>
    /// The computers this phone gave access to here (<c>listComputers</c>, answered <c>computerList</c>, which comes again
    /// whenever that list changes, on a connection that asked once).
    /// </summary>
    public const string ListComputers = "listComputers", ComputerList = "computerList";

    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("phoneID")] public string? PhoneID { get; set; }
    /// <summary>proof: the HMAC answer to the challenge (named for the protocol's first host, not a Mac).</summary>
    [JsonPropertyName("mac")] public string? Mac { get; set; }
    [JsonPropertyName("session")] public string? Session { get; set; }
    [JsonPropertyName("data")] public string? Data { get; set; }
    [JsonPropertyName("cols")] public int? Cols { get; set; }
    [JsonPropertyName("rows")] public int? Rows { get; set; }
    [JsonPropertyName("sessions")] public List<ShellSessionInfo>? SessionList { get; set; }
    [JsonPropertyName("history")] public List<ShellHistoryEntry>? HistoryEntries { get; set; }
    [JsonPropertyName("exitStatus")] public int? ExitStatus { get; set; }
    [JsonPropertyName("reason")] public string? Reason { get; set; }
    /// <summary>open: the phone's number for it, echoed in the <c>opened</c> or <c>error</c> answering it.</summary>
    [JsonPropertyName("ref")] public int? Ref { get; set; }
    [JsonPropertyName("done")] public bool? Done { get; set; }
    /// <summary>macInfo: the host's iroh endpoint id, home relay and relay token, and the addresses a phone can dial it on.</summary>
    [JsonPropertyName("irohID")] public string? IrohID { get; set; }
    [JsonPropertyName("irohRelay")] public string? IrohRelay { get; set; }
    [JsonPropertyName("relayToken")] public string? RelayToken { get; set; }
    [JsonPropertyName("addresses")] public List<string>? Addresses { get; set; }
    /// <summary>macState: how the host is doing, as this phone may see it.</summary>
    [JsonPropertyName("state")] public HostState? State { get; set; }
    /// <summary>setAwake / setVPN / viewing / pushState: on or off.</summary>
    [JsonPropertyName("on")] public bool? On { get; set; }
    [JsonPropertyName("push")] public PushRegistration? Push { get; set; }
    /// <summary>events: from when (Unix seconds). eventList: what happened since, oldest first, and the battery meanwhile.</summary>
    [JsonPropertyName("since")] public double? Since { get; set; }
    [JsonPropertyName("events")] public List<HostEvent>? EventEntries { get; set; }
    [JsonPropertyName("battery")] public List<BatterySample>? Battery { get; set; }
    /// <summary>screenGrant: the name the new viewer goes by on the host.</summary>
    [JsonPropertyName("name")] public string? Name { get; set; }
    /// <summary>screenGrant: the viewer's own id as the phone knows it.</summary>
    [JsonPropertyName("viewer")] public string? Viewer { get; set; }
    /// <summary>screenGranted: the new viewer's key (base64); its id is in <c>phoneID</c>.</summary>
    [JsonPropertyName("key")] public string? Key { get; set; }
    /// <summary>screenPass: what a host keeps to view another host's screen.</summary>
    [JsonPropertyName("pass")] public ShellCredentialWire? Pass { get; set; }
    /// <summary>host: what the host says about itself.</summary>
    [JsonPropertyName("host")] public HostInfo? HostInfo { get; set; }
    /// <summary>open: which of the host's shells to start (<see cref="HostShell.Id"/>).</summary>
    [JsonPropertyName("shell")] public string? Shell { get; set; }
    /// <summary>error: more about the reason (<c>rdp_unavailable</c>'s cause, in <see cref="HostInfo.Rdp"/>'s words).</summary>
    [JsonPropertyName("detail")] public string? Detail { get; set; }
    /// <summary>error: a sentence the host wrote, shown when the client has none of its own.</summary>
    [JsonPropertyName("message")] public string? Message { get; set; }
    /// <summary>error <c>try_later</c>: seconds until a retry can work.</summary>
    [JsonPropertyName("retryAfter")] public int? RetryAfter { get; set; }
    /// <summary>rdpReady: SHA-256 of the certificate Remote Desktop presents, lowercase hex.</summary>
    [JsonPropertyName("certSHA256")] public string? CertSHA256 { get; set; }
    /// <summary>computerGrant, computerGranted, computerPass: what the computer may do (<c>shell</c>, <c>screen</c>).</summary>
    [JsonPropertyName("scopes")] public List<string>? Scopes { get; set; }
    /// <summary>computerGranted, computerPass: scopes waiting for the owner at the host (<c>screen</c> on a PC).</summary>
    [JsonPropertyName("pending")] public List<string>? Pending { get; set; }
    /// <summary>computerGrant: the computer's identity public key (65-byte point, base64).</summary>
    [JsonPropertyName("idKey")] public string? IdKey { get; set; }
    /// <summary>computerGrant: what kind of computer it is (<c>mac</c>, <c>windows</c>).</summary>
    [JsonPropertyName("kind")] public string? Kind { get; set; }
    /// <summary>proof from a <c>computer.</c> id: the identity key's signature (raw r ‖ s, base64).</summary>
    [JsonPropertyName("sig")] public string? Sig { get; set; }
    /// <summary>computerList: the computers this phone gave access to.</summary>
    [JsonPropertyName("computers")] public List<ComputerListEntry>? Computers { get; set; }

    public ShellEnvelope() { }
    public ShellEnvelope(string t) { T = t; }

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
    public static ShellEnvelope Decode(ReadOnlySpan<byte> line)
    {
        ShellEnvelope? envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<ShellEnvelope>(line, Options);
        }
        catch (JsonException e)
        {
            throw new ProtocolException($"Not a shell message: {e.Message}");
        }
        if (envelope is null || string.IsNullOrEmpty(envelope.T))
            throw new ProtocolException("Shell message has no type");
        return envelope;
    }

    /// <summary>The type only: keys, proofs, tokens and output never reach a log through this.</summary>
    public override string ToString() => $"ShellEnvelope({T})";
}

/// <summary>One computer in <c>computerList</c>: what it may do now, what waits for the owner, and whether it is connected.</summary>
public sealed record ComputerListEntry
{
    [JsonPropertyName("phoneID")] public string PhoneID { get; init; } = "";
    /// <summary>The computer's id as the phone knows it (computerGrant's <c>viewer</c>); null when the host kept none.</summary>
    [JsonPropertyName("viewer")] public string? Viewer { get; init; }
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    [JsonPropertyName("scopes")] public List<string> Scopes { get; init; } = [];
    [JsonPropertyName("pending")] public List<string>? Pending { get; init; }
    [JsonPropertyName("connected")] public bool Connected { get; init; }
    /// <summary>Unix seconds.</summary>
    [JsonPropertyName("grantedAt")] public long GrantedAt { get; init; }
}
