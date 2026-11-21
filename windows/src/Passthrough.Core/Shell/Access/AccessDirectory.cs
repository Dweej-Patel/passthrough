using Passthrough.Core.Storage;

namespace Passthrough.Core.Shell.Access;

/// <summary>What the gate asks of whoever holds phones' keys: two keys to check a proof against, and what a phone may see.</summary>
public interface IShellAccess
{
    /// <summary>At most two keys (the current one first) for <paramref name="phoneId"/>; none for a phone nobody granted.</summary>
    IReadOnlyList<byte[]> CandidateKeys(string phoneId);

    /// <summary>The phone proved its current key: a previous one is no longer accepted.</summary>
    void ConfirmCurrentKey(string phoneId, ReadOnlySpan<byte> proven);

    bool ScreenAllowed(string phoneId);
}

/// <summary>
/// The service's phones, per Windows account (stage 4 plan, section 6): one <see cref="ShellAccessStore"/> per account
/// over its own slot (<c>shell.phones.&lt;SID&gt;</c>), so every rule of the Mac's store holds per account, and an index
/// from phone id to the account that owns it. A phone id belongs to one account: another account can't claim it, and
/// a phone only ever reaches its own account's shells.
/// </summary>
public sealed class AccessDirectory : IShellAccess
{
    public const string SlotPrefix = ShellAccessStore.Slot + ".";

    private readonly ISecretStore _secrets;
    private readonly Action<string>? _log;
    private readonly TimeProvider? _time;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, ShellAccessStore> _stores = new(StringComparer.OrdinalIgnoreCase);

    public AccessDirectory(ISecretStore secrets, TimeProvider? time = null, Action<string>? log = null)
    {
        _secrets = secrets;
        _time = time;
        _log = log;
        foreach (var slot in secrets.Slots().Where(s => s.StartsWith(SlotPrefix, StringComparison.Ordinal)))
            For(slot[SlotPrefix.Length..]);
    }

    /// <summary>Fires with the account whose phones changed.</summary>
    public event Action<string>? Changed;

    public IReadOnlyList<string> Accounts { get { lock (_lock) return [.. _stores.Keys]; } }

    /// <summary>The account's own store, made on first use.</summary>
    public ShellAccessStore For(string account)
    {
        lock (_lock)
        {
            if (_stores.TryGetValue(account, out var store)) return store;
            store = new ShellAccessStore(new SlotSuffix(_secrets, "." + account), _time, _log);
            store.Changed += () => Changed?.Invoke(account);
            _stores[account] = store;
            return store;
        }
    }

    /// <summary>The account a phone belongs to; null for one nobody granted.</summary>
    public string? Owner(string phoneId)
    {
        List<KeyValuePair<string, ShellAccessStore>> stores;
        lock (_lock) stores = [.. _stores];
        foreach (var (account, store) in stores)
            if (store.IsKnown(phoneId)) return account;
        return null;
    }

    public enum AddResult { Added, NotYours, Failed }

    /// <summary>Keeps a phone's key for <paramref name="account"/>; refused when another account already has that phone.</summary>
    public AddResult Add(string account, ShellPhone phone)
    {
        lock (_lock)
        {
            if (Owner(phone.PhoneId) is { } owner && !string.Equals(owner, account, StringComparison.OrdinalIgnoreCase)) return AddResult.NotYours;
            return For(account).Record(phone) ? AddResult.Added : AddResult.Failed;
        }
    }

    public IReadOnlyList<byte[]> CandidateKeys(string phoneId) => Owner(phoneId) is { } owner ? For(owner).CandidateKeys(phoneId) : [];

    public void ConfirmCurrentKey(string phoneId, ReadOnlySpan<byte> proven)
    {
        if (Owner(phoneId) is { } owner) For(owner).ConfirmCurrentKey(phoneId, proven);
    }

    public bool ScreenAllowed(string phoneId) => Owner(phoneId) is { } owner && For(owner).ScreenAllowed(phoneId);

    /// <summary>An <see cref="ISecretStore"/> whose slots carry a suffix: one account's view of the service's store.</summary>
    private sealed class SlotSuffix(ISecretStore inner, string suffix) : ISecretStore
    {
        public string? Get(string slot) => inner.Get(slot + suffix);
        public void Set(string slot, string value) => inner.Set(slot + suffix, value);
        public void Delete(string slot) => inner.Delete(slot + suffix);
        public IReadOnlyList<string> Slots() => [.. inner.Slots().Where(s => s.EndsWith(suffix, StringComparison.Ordinal)).Select(s => s[..^suffix.Length])];
    }
}
