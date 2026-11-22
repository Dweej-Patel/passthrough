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

    /// <summary>A computer with access (stage 7), with its effective scopes; null for one nobody granted (or a store that keeps none).</summary>
    ShellComputer? Computer(string id) => null;

    /// <summary>The phone may give its other computers access here.</summary>
    bool MayShare(string phoneId) => false;

    /// <summary>
    /// Gives a computer access for <paramref name="granter"/> (stage 7 a.2's rules, in order); the new id and key, the
    /// scopes and the pending ones, or the error the phone is told.
    /// </summary>
    (ShellComputer? Computer, ShellError? Error) GrantComputer(string granter, string name, string viewer, string? kind, byte[] identityKey,
        IReadOnlySet<string> scopes, bool screenNeedsOwner) => (null, ShellError.BadRequest);

    /// <summary>Takes back a computer <paramref name="granter"/> gave access to; false when it isn't one of its.</summary>
    bool RevokeComputer(string id, string granter) => false;

    /// <summary>The computers <paramref name="granter"/> gave access to, each with its effective scopes (none while its granter can't share them).</summary>
    IReadOnlyList<ShellComputer> ComputersGrantedBy(string granter) => [];
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

    /// <summary>
    /// Whether an account may use the service now (install.json's allowed accounts): a phone of an account an
    /// administrator disallowed proves nothing and reaches nothing, though its records stay until removal.
    /// </summary>
    public Func<string, bool> IsAllowed { get; set; } = _ => true;

    public AccessDirectory(ISecretStore secrets, TimeProvider? time = null, Action<string>? log = null)
    {
        _secrets = secrets;
        _time = time;
        _log = log;
        foreach (var slot in secrets.Slots().Where(s => s.StartsWith(SlotPrefix, StringComparison.Ordinal)))
            For(slot[SlotPrefix.Length..]);
    }

    /// <summary>A computer's access was replaced by a new grant for it: its connections must go.</summary>
    public event Action<string>? Replaced;

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
        {
            if (!IsAllowed(account)) continue;
            if (Computers.IsComputerId(phoneId) ? ComputersFor(account).Find(phoneId) is not null : store.IsKnown(phoneId)) return account;
        }
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

    public IReadOnlyList<byte[]> CandidateKeys(string phoneId)
    {
        if (Owner(phoneId) is not { } owner) return [];
        // A computer has one key: it is granted again under a new id, never re-keyed.
        return Computers.IsComputerId(phoneId) ? ComputersFor(owner).Find(phoneId) is { } c ? [c.Key] : [] : For(owner).CandidateKeys(phoneId);
    }

    private readonly Dictionary<string, ComputerAccessStore> _computers = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The account's computers (slot <c>shell.computers.&lt;SID&gt;</c>).</summary>
    public ComputerAccessStore ComputersFor(string account)
    {
        lock (_lock)
        {
            if (_computers.TryGetValue(account, out var store)) return store;
            store = new ComputerAccessStore(new SlotSuffix(_secrets, "." + account), _log);
            store.Changed += () => Changed?.Invoke(account);
            _computers[account] = store;
            return store;
        }
    }

    /// <summary>
    /// The computer with its effective scopes, asked on every request: shell while its granter keeps access (and, on a
    /// PC, its Shell switch); screen while its granter keeps Screen and the owner allowed it here (not pending).
    /// </summary>
    public ShellComputer? Computer(string id)
    {
        if (!Computers.IsComputerId(id) || Owner(id) is not { } owner || ComputersFor(owner).Find(id) is not { } c) return null;
        var phones = For(owner);
        var granter = c.GrantedBy is { } g ? phones.Phones.FirstOrDefault(p => p.PhoneId == g) : null;
        if (c.GrantedBy is not null && granter is null) return null;
        var direct = c.GrantedBy is null;
        return c with
        {
            Shell = c.Shell == true && (direct || granter is not null),
            Screen = c.Screen == true && c.ScreenPending != true && (direct || granter!.ScreenAllowed),
        };
    }

    public bool MayShare(string phoneId) => Owner(phoneId) is { } owner && For(owner).ShareAllowed(phoneId);

    public IReadOnlyList<ShellComputer> ComputersGrantedBy(string granter)
    {
        if (Computers.IsComputerId(granter) || Owner(granter) is not { } owner) return [];
        return [.. ComputersFor(owner).All.Where(c => c.GrantedBy == granter).OrderBy(c => c.GrantedAt)
            .Select(c => Computer(c.Id) ?? c with { Shell = false, Screen = false })];
    }

    public (ShellComputer? Computer, ShellError? Error) GrantComputer(string granter, string name, string viewer, string? kind, byte[] identityKey,
        IReadOnlySet<string> scopes, bool screenNeedsOwner)
    {
        name = ShellAccessStore.CleanLabel(name);
        if (name.Length == 0 || viewer.Length is 0 or > 128 || !ComputerProof.IsPoint(identityKey) || scopes.Count == 0 || !scopes.IsSubsetOf(Computers.Scopes))
            return (null, ShellError.BadRequest);
        if (!ShellAccessStore.IsPhoneId(granter) || Owner(granter) is not { } owner) return (null, ShellError.NotAuthorized);
        var phones = For(owner);
        if (!phones.ShareAllowed(granter)) return (null, ShellError.NotAllowed);
        if (scopes.Contains(Computers.ScopeScreen) && !phones.ScreenAllowed(granter)) return (null, ShellError.ScreenNotAllowed);
        lock (_lock)
        {
            var all = _stores.Keys.SelectMany(a => ComputersFor(a).All).ToList();
            // An older grant by the same phone for the same viewer is replaced, so it doesn't count.
            var others = all.Where(c => !(c.GrantedBy == granter && c.ViewerOf == viewer)).ToList();
            if (others.Count(c => c.GrantedBy == granter) >= Computers.MaxPerGranter || others.Count >= Computers.MaxTotal)
                return (null, ShellError.TooManyComputers);
            var screen = scopes.Contains(Computers.ScopeScreen);
            var computer = new ShellComputer
            {
                Id = Computers.NewId(),
                Name = name,
                Key = ShellAccessStore.NewKey(),
                IdentityKey = identityKey,
                Shell = scopes.Contains(Computers.ScopeShell) ? true : null,
                Screen = screen ? true : null,
                ScreenPending = screen && screenNeedsOwner ? true : null,
                Kind = kind is "mac" or "windows" ? kind : null,
                GrantedBy = granter,
                ViewerOf = viewer,
                PairingSlot = phones.Phones.First(p => p.PhoneId == granter).PairingSlot,
                GrantedAt = DateTimeOffset.UtcNow,
            };
            if (ComputersFor(owner).Add(computer) is not { } replaced) return (null, ShellError.BadRequest);
            foreach (var id in replaced) Replaced?.Invoke(id);
            return (computer, null);
        }
    }

    public bool RevokeComputer(string id, string granter) =>
        Owner(granter) is { } owner && ComputersFor(owner).Remove(c => c.Id == id && c.GrantedBy == granter).Count > 0;

    public void ConfirmCurrentKey(string phoneId, ReadOnlySpan<byte> proven)
    {
        if (Owner(phoneId) is { } owner) For(owner).ConfirmCurrentKey(phoneId, proven);
    }

    public bool ScreenAllowed(string phoneId) =>
        Computers.IsComputerId(phoneId) ? Computer(phoneId)?.Screen == true : Owner(phoneId) is { } owner && For(owner).ScreenAllowed(phoneId);

    /// <summary>An <see cref="ISecretStore"/> whose slots carry a suffix: one account's view of the service's store.</summary>
    private sealed class SlotSuffix(ISecretStore inner, string suffix) : ISecretStore
    {
        public string? Get(string slot) => inner.Get(slot + suffix);
        public void Set(string slot, string value) => inner.Set(slot + suffix, value);
        public void Delete(string slot) => inner.Delete(slot + suffix);
        public IReadOnlyList<string> Slots() => [.. inner.Slots().Where(s => s.EndsWith(suffix, StringComparison.Ordinal)).Select(s => s[..^suffix.Length])];
    }
}
