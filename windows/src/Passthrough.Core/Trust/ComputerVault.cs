using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Passthrough.Core.Shell;
using Passthrough.Core.Storage;

namespace Passthrough.Core.Trust;

/// <summary>
/// Windows Hello's key, for sealing (stage 8 a4): it can only sign, and its signature is deterministic (RSASSA-PKCS1-v1_5),
/// so a signature over a random salt is the secret a sealing key is derived from. Nothing usable is on disk without it.
/// </summary>
public interface IHelloSigner
{
    /// <summary>Hello is set up on this PC (a PIN is enough). Without it this PC can't keep access to other computers.</summary>
    Task<bool> IsAvailableAsync();

    /// <summary>The signature of <paramref name="challenge"/>, after the person confirms with Hello; null when they didn't.</summary>
    Task<byte[]?> SignAsync(byte[] challenge);
}

/// <summary>This computer's identity key (stage 7): signs its shell proofs as a viewer. Never the TLS or the iroh key.</summary>
public interface IComputerIdentity
{
    /// <summary>The 65-byte uncompressed P-256 point, what hosts record.</summary>
    byte[] PublicKey { get; }

    /// <summary>ECDSA P-256 SHA-256, raw r ‖ s (64 bytes).</summary>
    byte[] Sign(byte[] message);
}

/// <summary>Access to another computer this PC keeps (stage 7 a.5): the credential, what it may do, and who handed it over.</summary>
public sealed record ReachableComputer
{
    [JsonPropertyName("credential")] public ShellCredentialWire Credential { get; init; } = new();
    [JsonPropertyName("hostKind")] public string? HostKind { get; init; }
    [JsonPropertyName("scopes")] public List<string> Scopes { get; init; } = [];
    [JsonPropertyName("pending")] public List<string>? Pending { get; init; }
    /// <summary>The phone that handed it over (its label); null when paired directly.</summary>
    [JsonPropertyName("from")] public string? From { get; init; }
    [JsonPropertyName("fromPhoneID")] public string? FromPhoneId { get; init; }
    [JsonPropertyName("receivedAt")] public DateTimeOffset ReceivedAt { get; init; }

    [JsonIgnore] public string HostId => Credential.MacID;

    /// <summary>A computer. id, a 32-byte key, a 64-hex pin, a name: what a host can be dialled with.</summary>
    public bool IsUsable()
    {
        try
        {
            return Shell.Access.Computers.IsComputerId(Credential.PhoneID) && Convert.FromBase64String(Credential.ShellKey).Length == RemoteShell.KeyLength
                && Credential.CertSHA256.Length == 64 && Credential.CertSHA256.All(Uri.IsHexDigit) && Credential.MacName.Length is > 0 and <= 64 && Credential.MacID.Length > 0;
        }
        catch (FormatException) { return false; }
    }
}

/// <summary>
/// The computers this PC can reach, sealed with a key from Windows Hello (stage 8 a4) in one secret slot. Reading needs
/// one Hello confirmation per run; the list is then answered from memory. On a PC without Hello the fallback signer
/// (the Windows password) seals it instead, and the slot records which one did. A credential for a host already kept replaces
/// it only when its certificate and iroh id are the same (stage 7's replace rule): over iroh the viewer knows a host by
/// its id alone, so a swapped one would send the next sign-in to someone else.
/// </summary>
public sealed class ComputerReachStore(ISecretStore secrets, IHelloSigner hello, IHelloSigner? fallback = null)
{
    private const string ByHello = "hello", ByFallback = "password";
    public const string Slot = "computers.reach";
    public const int MaxComputers = 16;
    private static readonly byte[] Info = "passthrough-computers-v1"u8.ToArray();
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    private readonly SemaphoreSlim _gate = new(1, 1);
    private List<ReachableComputer>? _open;
    private byte[]? _salt, _key;
    private string? _by;

    public enum SaveResult { Saved, Conflict, NotUsable, Failed, Locked }

    /// <summary><c>By</c>: which signer sealed it (absent: Hello, the only one there was).</summary>
    private sealed record Sealed(int V, string Salt, string Nonce, string Box, string Tag, string? By = null);

    /// <summary>The computers, once opened (null until <see cref="UnlockAsync"/> worked).</summary>
    public IReadOnlyList<ReachableComputer>? Computers => _open;

    /// <summary>
    /// Opens the store with one confirmation, by the signer that sealed it; false when it was declined, there is no
    /// signer, or the data can't be opened. A new store is sealed with Hello when this PC has it, else the fallback.
    /// </summary>
    public async Task<bool> UnlockAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_open is not null) return true;
            var stored = secrets.Get(Slot) is { } text ? JsonSerializer.Deserialize<Sealed>(text, Json) : null;
            var helloHere = await hello.IsAvailableAsync().ConfigureAwait(false);
            // Sealed with Hello on a PC that doesn't have it now: nothing opens, and nothing is replaced. Hello can be
            // away for a while (it isn't offered in a Remote Desktop session), and a save would overwrite the slot.
            var by = stored is not null ? stored.By ?? ByHello : helloHere ? ByHello : ByFallback;
            var signer = by == ByHello ? (helloHere ? hello : null) : by == ByFallback ? fallback : null;
            if (signer is null || !await signer.IsAvailableAsync().ConfigureAwait(false)) return false;
            var salt = stored is null ? RandomNumberGenerator.GetBytes(32) : Convert.FromBase64String(stored.Salt);
            if (await signer.SignAsync(salt).ConfigureAwait(false) is not { } signature) return false;
            var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, signature, 32, salt, Info);
            List<ReachableComputer> list = [];
            if (stored is not null)
            {
                var plain = new byte[Convert.FromBase64String(stored.Box).Length];
                using var aes = new AesGcm(key, 16);
                aes.Decrypt(Convert.FromBase64String(stored.Nonce), Convert.FromBase64String(stored.Box), Convert.FromBase64String(stored.Tag), plain, Info);
                list = JsonSerializer.Deserialize<List<ReachableComputer>>(plain, Json) ?? [];
            }
            (_open, _salt, _key, _by) = (list, salt, key, by);
            return true;
        }
        catch (AuthenticationTagMismatchException)
        {
            // Sealed under a key that no longer exists (Hello reset or re-made, or the fallback's key lost): nothing in it can be opened again, so it
            // is set aside and the store starts empty; the computers in it need handing over again.
            secrets.Delete(Slot);
            return false;
        }
        catch (Exception e) when (e is CryptographicException or JsonException or FormatException) { return false; }
        finally { _gate.Release(); }
    }

    public async Task<SaveResult> SaveAsync(ReachableComputer computer, CancellationToken deadline = default)
    {
        if (!computer.IsUsable()) return SaveResult.NotUsable;
        if (!await UnlockAsync().ConfigureAwait(false)) return SaveResult.Locked;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            // Past the deadline the phone was told it failed: nothing is written.
            if (deadline.IsCancellationRequested) return SaveResult.Failed;
            var list = _open!.ToList();
            if (list.FirstOrDefault(c => c.HostId == computer.HostId) is { } kept
                && (kept.Credential.CertSHA256 != computer.Credential.CertSHA256 || kept.Credential.IrohID != computer.Credential.IrohID))
                return SaveResult.Conflict;
            list.RemoveAll(c => c.HostId == computer.HostId);
            list.Add(computer);
            if (list.Count > MaxComputers) return SaveResult.Failed;
            return Write(list) ? SaveResult.Saved : SaveResult.Failed;
        }
        finally { _gate.Release(); }
    }

    public async Task<bool> RemoveAsync(string hostId)
    {
        if (!await UnlockAsync().ConfigureAwait(false)) return false;
        await _gate.WaitAsync().ConfigureAwait(false);
        try { return Write([.. _open!.Where(c => c.HostId != hostId)]); }
        finally { _gate.Release(); }
    }

    private bool Write(List<ReachableComputer> list)
    {
        try
        {
            var plain = JsonSerializer.SerializeToUtf8Bytes(list, Json);
            var nonce = RandomNumberGenerator.GetBytes(12);
            var box = new byte[plain.Length];
            var tag = new byte[16];
            using (var aes = new AesGcm(_key!, 16)) aes.Encrypt(nonce, plain, box, tag, Info);
            secrets.Set(Slot, JsonSerializer.Serialize(new Sealed(1, Convert.ToBase64String(_salt!), Convert.ToBase64String(nonce), Convert.ToBase64String(box), Convert.ToBase64String(tag),
                _by == ByHello ? null : _by), Json));
            _open = list;
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException) { return false; }
    }
}
