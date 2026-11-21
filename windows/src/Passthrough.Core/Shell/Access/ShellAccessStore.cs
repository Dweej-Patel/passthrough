using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Passthrough.Core.Storage;

namespace Passthrough.Core.Shell.Access;

/// <summary>A phone the owner has allowed to open shells on this PC (a port of ShellPhone in ShellAccessStore.swift).</summary>
public sealed record ShellPhone
{
    [JsonPropertyName("phoneID")] public string PhoneId { get; init; } = "";
    [JsonPropertyName("label")] public string Label { get; init; } = "";
    [JsonPropertyName("pairingSlot")] public string PairingSlot { get; init; } = "";
    /// <summary>The per-phone shell key. A secret: never log it.</summary>
    [JsonPropertyName("key")] public byte[] Key { get; init; } = [];
    /// <summary>The key before its latest grant, accepted until the phone first proves <see cref="Key"/>. A secret too.</summary>
    [JsonPropertyName("previousKey")] public byte[]? PreviousKey { get; init; }
    [JsonPropertyName("grantedAt")] public DateTimeOffset GrantedAt { get; init; }
    /// <summary>The owner also lets this phone see and control the screen. Off unless turned on.</summary>
    [JsonPropertyName("screen")] public bool? Screen { get; init; }

    [JsonIgnore] public bool ScreenAllowed => Screen ?? false;

    public bool Equals(ShellPhone? other) => other is not null && PhoneId == other.PhoneId && Label == other.Label
        && PairingSlot == other.PairingSlot && Key.AsSpan().SequenceEqual(other.Key) && GrantedAt == other.GrantedAt && Screen == other.Screen
        && (PreviousKey is null ? other.PreviousKey is null : other.PreviousKey is not null && PreviousKey.AsSpan().SequenceEqual(other.PreviousKey));

    public override int GetHashCode() => HashCode.Combine(PhoneId, PairingSlot);
}

/// <summary>
/// The phones allowed a shell on this PC, with their keys, kept in the secret store (a port of ShellAccessStore.swift,
/// without the Mac's screen passes: a PC issues none). The list is read from the store, then answered from memory: the
/// listener asks on every handshake. A read that finds nothing stands for <see cref="EmptyTtl"/> only, so a stranger's
/// handshakes can't make each one go to the store. Taking access away fails closed: a revoke or Screen turned off holds
/// in memory even when the store can't be written, and is laid over every later read until a write succeeds.
/// Thread-safe; the lock guarding the copy is never held across store I/O, and writes serialize on their own.
/// </summary>
public sealed class ShellAccessStore
{
    internal const string Slot = "shell.phones";
    public static readonly TimeSpan EmptyTtl = TimeSpan.FromSeconds(5);
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly ISecretStore _secrets;
    private readonly TimeProvider _time;
    private readonly Action<string>? _log;
    private readonly Lock _lock = new();
    private readonly Lock _writeLock = new();
    private List<ShellPhone>? _cached;
    private DateTimeOffset? _emptyUntil;
    private int _generation;
    private readonly HashSet<string> _unsavedRevokes = [];
    private readonly HashSet<string> _unsavedScreenOff = [];

    public ShellAccessStore(ISecretStore secrets, TimeProvider? time = null, Action<string>? log = null)
    {
        _secrets = secrets;
        _time = time ?? TimeProvider.System;
        _log = log;
    }

    /// <summary>Fires after the list changes through this store (on the writer's thread).</summary>
    public event Action? Changed;

    public IReadOnlyList<ShellPhone> Phones
    {
        get
        {
            int seen;
            lock (_lock)
            {
                if (_cached is not null && (_emptyUntil is null || _time.GetUtcNow() < _emptyUntil)) return _cached;
                seen = _generation;
            }
            var loaded = ReadStore();
            if (loaded is null) return [];
            lock (_lock)
            {
                if (_generation == seen && (_cached is null || _emptyUntil is not null))
                {
                    _cached = loaded;
                    _emptyUntil = loaded.Count == 0 ? _time.GetUtcNow() + EmptyTtl : null;
                }
            }
            return loaded;
        }
    }

    /// <summary>32 random bytes.</summary>
    public static byte[] NewKey() => RandomNumberGenerator.GetBytes(RemoteShell.KeyLength);

    /// <summary>
    /// Adds the phone, replacing an earlier grant for the same id; the key it last proved stays accepted as
    /// <see cref="ShellPhone.PreviousKey"/> until the new one is first used. False when it couldn't be stored (or the
    /// stored list is unreadable and must not be overwritten), when the id isn't a phone's, or when that id was granted
    /// through another pairing: the id is the phone's own claim, so one paired phone must not take over another's access.
    /// </summary>
    public bool Record(ShellPhone phone)
    {
        if (!IsPhoneId(phone.PhoneId)) { _log?.Invoke("shell: an id that isn't a phone's was offered for access; not recording it"); return false; }
        lock (_writeLock)
        {
            if (LoadForWrite() is not { } list) { _log?.Invoke("shell: the stored phones are unreadable; not recording a new one"); return false; }
            var before = list;
            if (list.FirstOrDefault(p => p.PhoneId == phone.PhoneId) is { } earlier)
            {
                if (earlier.PairingSlot != phone.PairingSlot)
                {
                    _log?.Invoke("shell: a phone claimed the access of a phone granted through another pairing; not recording it");
                    return false;
                }
                // An unconfirmed earlier grant was never used, so the phone may still hold only the key before it.
                var kept = earlier.PreviousKey ?? earlier.Key;
                // Plugging the phone in again renews its key, not what it may do.
                phone = phone with { PreviousKey = kept.AsSpan().SequenceEqual(phone.Key) ? null : kept, Screen = earlier.Screen };
            }
            return Store([.. list.Where(p => p.PhoneId != phone.PhoneId), phone], before);
        }
    }

    /// <summary>
    /// A phone's id, by the cable's own rule (<see cref="Control.ControlClient"/>: 1 to 64 letters, digits, <c>.</c>, <c>_</c>
    /// or <c>-</c>). The ids a host mints for other kinds of access (<c>viewer.</c>, <c>computer.</c>) are never a phone's.
    /// </summary>
    public static bool IsPhoneId(string? id) =>
        Control.ControlClient.IsPhoneId(id)
        && !id!.StartsWith("viewer.", StringComparison.Ordinal) && !id.StartsWith("computer.", StringComparison.Ordinal);

    /// <summary>The keys a proof from this phone may use: its current key, then the previous one while still accepted.</summary>
    public IReadOnlyList<byte[]> CandidateKeys(string phoneId) =>
        Phones.FirstOrDefault(p => p.PhoneId == phoneId) is { } phone ? phone.PreviousKey is { } previous ? [phone.Key, previous] : [phone.Key] : [];

    public bool IsKnown(string phoneId) => Phones.Any(p => p.PhoneId == phoneId);

    public bool ScreenAllowed(string phoneId) => Phones.FirstOrDefault(p => p.PhoneId == phoneId)?.ScreenAllowed ?? false;

    /// <summary>
    /// The phone proved <paramref name="proven"/>, its current key: the previous key stops working. Nothing changes if
    /// it was granted again meanwhile. Writes only when there is a key to drop.
    /// </summary>
    public void ConfirmCurrentKey(string phoneId, ReadOnlySpan<byte> proven)
    {
        lock (_writeLock)
        {
            if (LoadForWrite() is not { } list) return;
            var index = list.FindIndex(p => p.PhoneId == phoneId);
            if (index < 0 || list[index].PreviousKey is null || !list[index].Key.AsSpan().SequenceEqual(proven)) return;
            var next = new List<ShellPhone>(list) { [index] = list[index] with { PreviousKey = null } };
            if (!Store(next, list)) _log?.Invoke("shell: could not drop a phone's previous key");
        }
    }

    /// <summary>
    /// Lets the phone see and control the screen, or stops it. A failed allow changes nothing; a failed stop still
    /// stops it, in memory, until the store can be written (false: say it may come back after a restart).
    /// </summary>
    public bool SetScreenAllowed(string phoneId, bool allowed)
    {
        lock (_writeLock)
        {
            if (LoadForWrite() is not { } list) return false;
            var index = list.FindIndex(p => p.PhoneId == phoneId);
            if (index < 0) return false;
            var next = new List<ShellPhone>(list) { [index] = list[index] with { Screen = allowed } };
            if (allowed) return Store(next, list);
            SetCache(next);
            if (Write(next)) { Saved(); Changed?.Invoke(); return true; }
            _log?.Invoke("shell: could not store that a phone may no longer see the screen; it stays off until Passthrough quits");
            lock (_lock) _unsavedScreenOff.Add(phoneId);
            Changed?.Invoke();
            return false;
        }
    }

    /// <summary>The phone granted through <paramref name="pairingSlot"/> now goes by <paramref name="label"/>; true only if a stored label changed.</summary>
    public bool Relabel(string pairingSlot, string label)
    {
        if (label.Length == 0 || !Phones.Any(p => p.PairingSlot == pairingSlot && p.Label != label)) return false;
        lock (_writeLock)
        {
            if (LoadForWrite() is not { } list) return false;
            return Store([.. list.Select(p => p.PairingSlot == pairingSlot ? p with { Label = label } : p)], list);
        }
    }

    /// <summary>Removes the phone. Returns whether it is surely gone, and what was removed (cut its connections either way).</summary>
    public (bool Done, IReadOnlyList<ShellPhone> Removed) Revoke(string phoneId) => Removing(p => p.PhoneId == phoneId);

    /// <summary>Removes every phone granted through this pairing slot (its pairing was forgotten).</summary>
    public (bool Done, IReadOnlyList<ShellPhone> Removed) RevokeSlot(string pairingSlot) => Removing(p => p.PairingSlot == pairingSlot);

    /// <summary>
    /// Revocation fails closed: the phone leaves the in-memory list first, so it is refused at once; if the stored list
    /// then can't be rewritten (or read), it is deleted whole rather than left holding a revoked key.
    /// </summary>
    private (bool Done, IReadOnlyList<ShellPhone> Removed) Removing(Func<ShellPhone, bool> shouldRemove)
    {
        lock (_writeLock)
        {
            if (LoadForWrite() is { } list)
            {
                var entries = list.Where(shouldRemove).ToList();
                if (entries.Count == 0) return (true, []);
                var next = list.Where(p => !shouldRemove(p)).ToList();
                SetCache(next);
                if (Write(next)) { Saved(); Changed?.Invoke(); return (true, entries); }
                _log?.Invoke("shell: could not update the stored phones; removing them all");
                var gone = DeleteStored();
                if (gone) { SetCache(null); Saved(); }
                else lock (_lock) _unsavedRevokes.UnionWith(entries.Select(e => e.PhoneId));
                Changed?.Invoke();
                return (gone, entries);
            }
            _log?.Invoke("shell: the stored phones are unreadable; removing them all");
            List<ShellPhone> everyone;
            lock (_lock) everyone = _cached ?? [];
            SetCache(null);
            var deleted = DeleteStored();
            Changed?.Invoke();
            return (deleted, everyone.Where(shouldRemove).ToList());
        }
    }

    private bool DeleteStored()
    {
        try { _secrets.Delete(Slot); return _secrets.Get(Slot) is null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException) { return false; }
    }

    private void SetCache(List<ShellPhone>? list)
    {
        lock (_lock) { _cached = list; _emptyUntil = null; _generation++; }
    }

    private void Saved()
    {
        lock (_lock) { _unsavedRevokes.Clear(); _unsavedScreenOff.Clear(); }
    }

    private bool Write(List<ShellPhone> list)
    {
        try
        {
            if (list.Count == 0) return DeleteStored();
            _secrets.Set(Slot, JsonSerializer.Serialize(list, Json));
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException) { return false; }
    }

    /// <summary>Under the write lock.</summary>
    private bool Store(List<ShellPhone> list, List<ShellPhone> previous)
    {
        if (list.SequenceEqual(previous)) return true;
        if (Write(list)) { SetCache(list); Saved(); Changed?.Invoke(); return true; }
        SetCache(null); // whatever the store holds now, read it again
        return false;
    }

    /// <summary>The list to modify, under the write lock: null when something is stored but unreadable.</summary>
    private List<ShellPhone>? LoadForWrite()
    {
        List<ShellPhone>? current;
        lock (_lock) current = _emptyUntil is null ? _cached : null;
        if (current is not null) return current;
        var loaded = ReadStore();
        if (loaded is { Count: > 0 }) SetCache(loaded);
        return loaded;
    }

    /// <summary>From the store, with the unsaved reductions applied: empty when nothing is stored, null when unreadable.</summary>
    private List<ShellPhone>? ReadStore()
    {
        List<ShellPhone> list = [];
        try
        {
            if (_secrets.Get(Slot) is { } text)
            {
                var stored = JsonSerializer.Deserialize<List<ShellPhone>>(text, Json);
                if (stored is null) return null;
                // Anything that isn't a phone with a whole key can't be used: left out, never taken for one.
                list = [.. stored.Where(p => IsPhoneId(p.PhoneId) && p.Key.Length == RemoteShell.KeyLength)];
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or CryptographicException or FormatException) { return null; }
        HashSet<string> revoked, screenOff;
        lock (_lock) { revoked = [.. _unsavedRevokes]; screenOff = [.. _unsavedScreenOff]; }
        return [.. list.Where(p => !revoked.Contains(p.PhoneId)).Select(p => screenOff.Contains(p.PhoneId) ? p with { Screen = false } : p)];
    }
}
