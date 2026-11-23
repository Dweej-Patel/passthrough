namespace Passthrough.Core.Shell;

/// <summary>
/// Slots for connections that have not proved anything yet (a port of HandshakeLimiter.swift): anyone on the same
/// network can connect, so a stranger may hold a couple of handshakes, never all of them, and none for longer than the
/// handshake timeout. A stranger with many addresses is counted by network (<see cref="Bucket"/>), and a few slots are
/// kept for addresses that proved themselves lately (remembered across launches by an <see cref="IProvenAddressStore"/>),
/// so the owner's phones still get in while someone holds every other slot. Thread-safe.
/// </summary>
public sealed class HandshakeLimiter
{
    /// <summary>Handshakes at once, in all and from one address (or network).</summary>
    public const int MaxHandshakes = 16;
    public const int MaxHandshakesPerHost = 2;
    /// <summary>Of <see cref="MaxHandshakes"/>, how many only addresses that proved themselves within <see cref="ProvenFor"/> may take.</summary>
    public const int ReservedForProven = 4;
    public static readonly TimeSpan ProvenFor = TimeSpan.FromDays(30);
    /// <summary>Most proven addresses remembered; the longest unproven go first.</summary>
    internal const int ProvenLimit = 256;
    /// <summary>How stale the stored date of an address proven again may get before it is written anew (a new address is written at once).</summary>
    internal static readonly TimeSpan ResaveInterval = TimeSpan.FromHours(1);

    /// <summary>One handshake's hold on a slot, freed once: by the handshake finishing or by the timeout.</summary>
    public sealed class Slot
    {
        private readonly HandshakeLimiter _limiter;
        private readonly string _key;
        private int _released;
        internal ITimer? Timer;

        internal Slot(HandshakeLimiter limiter, string key) => (_limiter, _key) = (limiter, key);

        public bool IsReleased => Volatile.Read(ref _released) != 0;

        /// <summary>Frees the slot; false if it was already freed (the timeout won).</summary>
        public bool Release()
        {
            if (Interlocked.Exchange(ref _released, 1) != 0) return false;
            Timer?.Dispose();
            _limiter.Free(_key);
            return true;
        }
    }

    private readonly Lock _lock = new();
    private readonly TimeSpan _timeout;
    private readonly int _maxTotal;
    private readonly int _maxPerHost;
    private readonly int _reserved;
    private readonly TimeProvider _time;
    private readonly IProvenAddressStore _store;
    private int _pending;
    private readonly Dictionary<string, int> _pendingByKey = [];
    private Dictionary<string, DateTimeOffset> _provenAt;
    private DateTimeOffset _lastSaved = DateTimeOffset.MinValue;

    /// <param name="timeout">How long an unproven connection may hold its slot (10 s on the shell's paths).</param>
    /// <param name="store">Keeps the proven addresses across launches; read once here.</param>
    public HandshakeLimiter(TimeSpan timeout, TimeProvider time, IProvenAddressStore? store = null, int maxTotal = MaxHandshakes,
        int maxPerHost = MaxHandshakesPerHost, int reservedForProven = ReservedForProven)
    {
        _timeout = timeout;
        _time = time;
        _store = store ?? new MemoryProvenAddressStore();
        _maxTotal = maxTotal;
        _maxPerHost = maxPerHost;
        _reserved = Math.Min(reservedForProven, maxTotal);
        _provenAt = Kept(_store.Load(), time.GetUtcNow());
    }

    /// <summary>Handshakes holding a slot now.</summary>
    public int Count
    {
        get { lock (_lock) return _pending; }
    }

    /// <summary>
    /// A slot for a handshake from <paramref name="host"/>, or null when it must be refused. <paramref name="maxForHost"/>
    /// overrides the per-host cap for this bucket (relayed iroh attempts share one bucket with a larger cap). An address
    /// that proved itself lately is counted on its own, not in its network's bucket, and may also take the reserved
    /// slots. If the handshake has not released it within the timeout, the slot is freed and <paramref name="onTimeout"/>
    /// runs (to drop the connection).
    /// </summary>
    public Slot? Acquire(string host, Action onTimeout, int? maxForHost = null)
    {
        Slot slot;
        lock (_lock)
        {
            var trusted = IsProvenLocked(host);
            var key = trusted ? "proven/" + ShellAddressPolicy.Bare(host) : Bucket(host);
            var limit = trusted ? _maxTotal : _maxTotal - _reserved;
            if (_pending >= limit || _pendingByKey.GetValueOrDefault(key) >= (maxForHost ?? _maxPerHost)) return null;
            _pending++;
            _pendingByKey[key] = _pendingByKey.GetValueOrDefault(key) + 1;
            slot = new Slot(this, key);
        }
        slot.Timer = _time.CreateTimer(_ => { if (slot.Release()) onTimeout(); }, null, _timeout, Timeout.InfiniteTimeSpan);
        return slot;
    }

    /// <summary>
    /// A handshake from <paramref name="host"/> proved itself: for <see cref="ProvenFor"/> it is counted on its own and
    /// may use the reserved slots. Only IP addresses are remembered, never a shared bucket such as relayed attempts'.
    /// </summary>
    public void Proven(string host)
    {
        var bare = ShellAddressPolicy.Bare(host);
        if (!IsAddress(bare)) return;
        Dictionary<string, DateTimeOffset>? save = null;
        lock (_lock)
        {
            var now = _time.GetUtcNow();
            var isNew = !_provenAt.ContainsKey(bare);
            _provenAt[bare] = now;
            if (_provenAt.Count > ProvenLimit) _provenAt.Remove(_provenAt.MinBy(p => p.Value).Key);
            if (!isNew && now - _lastSaved < ResaveInterval) return;
            _provenAt = Kept(_provenAt, now);
            _lastSaved = now;
            save = new(_provenAt);
        }
        _store.Save(save);
    }

    internal bool IsProven(string host)
    {
        lock (_lock) return IsProvenLocked(host);
    }

    private bool IsProvenLocked(string host)
    {
        var bare = ShellAddressPolicy.Bare(host);
        if (!_provenAt.TryGetValue(bare, out var at)) return false;
        if (_time.GetUtcNow() - at < ProvenFor) return true;
        _provenAt.Remove(bare);
        return false;
    }

    private void Free(string key)
    {
        lock (_lock)
        {
            _pending--;
            var left = _pendingByKey.GetValueOrDefault(key, 1) - 1;
            if (left > 0) _pendingByKey[key] = left;
            else _pendingByKey.Remove(key);
        }
    }

    /// <summary>
    /// <paramref name="table"/> without expired entries or anything but addresses, and at most <see cref="ProvenLimit"/>
    /// of the newest. A date in the future (the clock was set back) counts as now.
    /// </summary>
    internal static Dictionary<string, DateTimeOffset> Kept(IReadOnlyDictionary<string, DateTimeOffset> table, DateTimeOffset now) =>
        table.Select(p => (p.Key, At: p.Value > now ? now : p.Value))
            .Where(p => IsAddress(p.Key) && now - p.At < ProvenFor)
            .OrderByDescending(p => p.At)
            .Take(ProvenLimit)
            .ToDictionary(p => p.Key, p => p.At);

    /// <summary>
    /// What a peer is counted under, so taking many addresses in one network does not multiply a stranger's share: a
    /// public IPv4 peer by its /24, and a ULA or global IPv6 peer by its /64. A private, loopback, link-local or
    /// shared-space IPv4 peer is counted by its own address, and so is a link-local IPv6 one (every neighbour shares
    /// fe80::/64). A <c>%scope</c> suffix is ignored.
    /// </summary>
    internal static string Bucket(string host)
    {
        var bare = ShellAddressPolicy.Bare(host);
        if (ShellAddressPolicy.ParseV4(bare) is { } b)
        {
            var own = b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] is >= 64 and <= 127);
            return own ? "v4/" + bare : $"v4/{b[0]}.{b[1]}.{b[2]}.0/24";
        }
        if (ShellAddressPolicy.ParseV6(bare) is not { } raw) return host;
        var linkLocal = raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80;
        return "v6/" + Convert.ToHexString(raw, 0, linkLocal ? 16 : 8).ToLowerInvariant();
    }

    private static bool IsAddress(string bare) => ShellAddressPolicy.ParseV4(bare) is not null || ShellAddressPolicy.ParseV6(bare) is not null;
}

/// <summary>Where a <see cref="HandshakeLimiter"/> keeps the addresses that proved themselves (bare address, when it last did). Give each listener its own.</summary>
public interface IProvenAddressStore
{
    IReadOnlyDictionary<string, DateTimeOffset> Load();
    void Save(IReadOnlyDictionary<string, DateTimeOffset> proven);
}

/// <summary>Forgotten when the app quits (tests, and listeners nothing is kept for).</summary>
public sealed class MemoryProvenAddressStore(IReadOnlyDictionary<string, DateTimeOffset>? table = null) : IProvenAddressStore
{
    private readonly Lock _lock = new();
    private IReadOnlyDictionary<string, DateTimeOffset> _table = table ?? new Dictionary<string, DateTimeOffset>();

    public IReadOnlyDictionary<string, DateTimeOffset> Load()
    {
        lock (_lock) return _table;
    }

    public void Save(IReadOnlyDictionary<string, DateTimeOffset> proven)
    {
        lock (_lock) _table = proven;
    }
}
