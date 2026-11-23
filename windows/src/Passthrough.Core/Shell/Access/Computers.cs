using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Passthrough.Core.Storage;

namespace Passthrough.Core.Shell.Access;

/// <summary>Computers given access to this host (stage 7, track a): their ids, caps and scopes.</summary>
public static class Computers
{
    public const string IdPrefix = "computer.";
    public const int MaxPerGranter = 8, MaxTotal = 16;
    public const string ScopeShell = "shell", ScopeScreen = "screen";
    public static readonly IReadOnlySet<string> Scopes = new HashSet<string> { ScopeShell, ScopeScreen };

    /// <summary>Any id with the prefix is a computer, whatever the store says (fails closed).</summary>
    public static bool IsComputerId(string? id) => id?.StartsWith(IdPrefix, StringComparison.Ordinal) == true;

    public static string NewId() => IdPrefix + Guid.NewGuid().ToString("D");
}

/// <summary>
/// The second half of a computer's proof (stage 7 a.1; RECONCILIATION's computer proof): ECDSA P-256 over
/// <c>"passthrough-computer-v1" ‖ 0x00 ‖ path ‖ nonce ‖ hostBinding ‖ id</c>, the signature raw <c>r ‖ s</c>. The
/// binding (the host certificate's SHA-256 on TLS, its endpoint id on iroh) makes a signature good for one host only,
/// so a copied credential opens nothing without the computer's own key.
/// </summary>
public static class ComputerProof
{
    public const string Label = "passthrough-computer-v1";
    public const byte PathTls = 1, PathIroh = 2;

    /// <summary>A valid point (P-256's generator) to verify against when there is no real key: the same work either way.</summary>
    public static readonly byte[] DecoyKey = Convert.FromHexString(
        "046B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C2964FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5");

    /// <summary>A well-formed signature (r and s nonzero, below the curve order) for the decoy check, so it does the full work.</summary>
    public static readonly byte[] DecoySignature = [.. Enumerable.Repeat((byte)0x5A, 32), .. Enumerable.Repeat((byte)0x3C, 32)];

    public static byte[] Message(ReadOnlySpan<byte> nonce, byte path, ReadOnlySpan<byte> hostBinding, string computerId) =>
        [.. Encoding.UTF8.GetBytes(Label), 0x00, path, .. nonce, .. hostBinding, .. Encoding.UTF8.GetBytes(computerId)];

    /// <summary>A 65-byte uncompressed point.</summary>
    public static bool IsPoint(byte[]? key) => key is { Length: 65 } && key[0] == 0x04;

    public static bool IsValid(ReadOnlySpan<byte> signature, byte[] publicKey, ReadOnlySpan<byte> message)
    {
        if (signature.Length != 64 || !IsPoint(publicKey)) return false;
        try
        {
            using var ecdsa = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = publicKey[1..33], Y = publicKey[33..65] },
            });
            return ecdsa.VerifyData(message, signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (CryptographicException) { return false; }
    }
}

/// <summary>Which listener a proof came through, and what it binds a computer's signature to.</summary>
public sealed record ProofBinding(byte Path, byte[] HostBinding);

/// <summary>A computer a phone gave access to (stage 7 a.2). Its key and identity key are secrets of a kind: never logged.</summary>
public sealed record ShellComputer
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("key")] public byte[] Key { get; init; } = [];
    /// <summary>The computer's identity public key (65 bytes): every proof is also signed with it.</summary>
    [JsonPropertyName("identityKey")] public byte[] IdentityKey { get; init; } = [];
    [JsonPropertyName("shell")] public bool? Shell { get; init; }
    [JsonPropertyName("screen")] public bool? Screen { get; init; }
    /// <summary>A phone asked for the screen: not usable until the owner allows it at this PC.</summary>
    [JsonPropertyName("screenPending")] public bool? ScreenPending { get; init; }
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    /// <summary>The phone that granted it (removing that phone removes it); null for one paired directly.</summary>
    [JsonPropertyName("grantedBy")] public string? GrantedBy { get; init; }
    /// <summary>The computer's own host id, so a new grant for it replaces the old.</summary>
    [JsonPropertyName("viewerOf")] public string ViewerOf { get; init; } = "";
    [JsonPropertyName("pairingSlot")] public string PairingSlot { get; init; } = "";
    [JsonPropertyName("grantedAt")] public DateTimeOffset GrantedAt { get; init; }
    /// <summary>Not used yet: an earlier grant to the same computer from the same phone keeps working until this one is.</summary>
    [JsonPropertyName("fresh")] public bool? Fresh { get; init; }
}

/// <summary>
/// The computers given access to one account's shells (slot <c>shell.computers</c>, apart from the phones so a build
/// from before this stage reads none of them as a phone). Answered from memory; taking access away fails closed
/// (memory first, then the store, and the whole slot deleted if it can't be rewritten).
/// </summary>
public sealed class ComputerAccessStore(ISecretStore secrets, Action<string>? log = null)
{
    internal const string Slot = "shell.computers";
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    private readonly Lock _lock = new();
    private List<ShellComputer>? _cached;

    public event Action? Changed;

    public IReadOnlyList<ShellComputer> All
    {
        get
        {
            lock (_lock)
            {
                if (_cached is not null) return _cached;
                _cached = Read();
                return _cached;
            }
        }
    }

    public ShellComputer? Find(string id) => All.FirstOrDefault(c => c.Id == id);

    /// <summary>One per computer and phone: the newest grant (an older one still working until it is used is left out).</summary>
    public IReadOnlyList<ShellComputer> Current =>
        [.. All.GroupBy(c => (c.GrantedBy, c.ViewerOf)).Select(g => g.OrderByDescending(c => c.GrantedAt).First())];

    /// <summary>
    /// <paramref name="id"/> was used: it is no longer fresh, and the grants it replaced (same computer, same phone) go;
    /// their ids come back so their connections can be cut.
    /// </summary>
    public IReadOnlyList<string> Used(string id)
    {
        List<string> retired;
        lock (_lock)
        {
            if (All.FirstOrDefault(c => c.Id == id) is not { Fresh: true } used) return [];
            retired = [.. All.Where(c => c.Id != id && c.ViewerOf == used.ViewerOf && c.GrantedBy == used.GrantedBy).Select(c => c.Id)];
            var next = All.Where(c => !retired.Contains(c.Id)).Select(c => c.Id == id ? c with { Fresh = null } : c).ToList();
            _cached = next;
            if (!Write(next)) log?.Invoke("shell: could not store that a computer's new access was used; the old one is gone from memory");
        }
        Changed?.Invoke();
        return retired;
    }

    private List<ShellComputer> Read()
    {
        try
        {
            if (secrets.Get(Slot) is not { } text) return [];
            var stored = JsonSerializer.Deserialize<List<ShellComputer>>(text, Json) ?? [];
            return [.. stored.Where(c => Computers.IsComputerId(c.Id) && c.Key.Length == RemoteShell.KeyLength && ComputerProof.IsPoint(c.IdentityKey))];
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or CryptographicException) { return []; }
    }

    private bool Write(List<ShellComputer> list)
    {
        try
        {
            if (list.Count == 0) secrets.Delete(Slot);
            else secrets.Set(Slot, JsonSerializer.Serialize(list, Json));
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException) { return false; }
    }

    /// <summary>
    /// Keeps <paramref name="computer"/> (fresh), replacing an earlier one for the same viewer from the same granter that
    /// was never used; one that was used keeps working until the new one is (<see cref="Used"/>), so a hand-over that
    /// fails on the phone's way leaves the computer its access. The ids replaced now come back so their connections can
    /// be cut. Null when it couldn't be stored.
    /// </summary>
    public IReadOnlyList<string>? Add(ShellComputer computer)
    {
        List<string> replaced;
        computer = computer with { Fresh = true };
        lock (_lock)
        {
            replaced = [.. All.Where(c => c.ViewerOf == computer.ViewerOf && c.GrantedBy == computer.GrantedBy && c.Fresh == true).Select(c => c.Id)];
            var next = All.Where(c => !replaced.Contains(c.Id)).Append(computer).ToList();
            if (!Write(next)) return null;
            _cached = next;
        }
        Changed?.Invoke();
        return replaced;
    }

    /// <summary>Removes what matches: from memory first, then the store; the whole slot if it can't be rewritten.</summary>
    public IReadOnlyList<ShellComputer> Remove(Func<ShellComputer, bool> which)
    {
        List<ShellComputer> removed;
        lock (_lock)
        {
            removed = [.. All.Where(which)];
            if (removed.Count == 0) return [];
            var next = All.Where(c => !which(c)).ToList();
            _cached = next;
            if (!Write(next))
            {
                log?.Invoke("shell: could not update the stored computers; removing them all");
                try { secrets.Delete(Slot); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        Changed?.Invoke();
        return removed;
    }

    public bool SetScreen(string id, bool on, bool pending = false)
    {
        lock (_lock)
        {
            var list = All.ToList();
            var i = list.FindIndex(c => c.Id == id);
            if (i < 0) return false;
            list[i] = list[i] with { Screen = on || pending ? true : false, ScreenPending = pending ? true : null };
            _cached = list; // off holds in memory even when it can't be written
            if (!Write(list) && on) return false;
        }
        Changed?.Invoke();
        return true;
    }
}
