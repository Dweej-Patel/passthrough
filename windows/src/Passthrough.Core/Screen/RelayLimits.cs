namespace Passthrough.Core.Screen;

/// <summary>
/// How often a grant may open the screen (RECONCILIATION's relay caps): the relay can't see a sign-in fail (it carries
/// encrypted bytes), so it limits what it can see. Per grant (account, id): at most <see cref="CapFor"/> counted opens
/// in any 10 minutes; 12 in all per PC. An open counts from <c>rdpReady</c>; once it has lasted over 30 s it stops
/// counting, so a session that works is free and quick failures (what guessing looks like) add up. In memory: a
/// restart resets it, and Windows' own lockout is the backstop.
/// </summary>
public sealed class RelayRateLimit(TimeProvider? time = null)
{
    public static readonly TimeSpan Window = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan Free = TimeSpan.FromSeconds(30);
    public const int DefaultCap = 4, TotalCap = 12;

    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly Lock _lock = new();
    private readonly List<Ticket> _opens = [];

    /// <summary>Windows' account lockout threshold (0: none), read by the service; the cap stays below it.</summary>
    public int LockoutThreshold { get; set; }

    public int CapFor => LockoutThreshold is >= 1 and <= DefaultCap ? Math.Max(1, LockoutThreshold - 1) : DefaultCap;

    public sealed class Ticket(string account, string id, DateTimeOffset openedAt)
    {
        public string Account { get; } = account;
        public string Id { get; } = id;
        public DateTimeOffset OpenedAt { get; } = openedAt;
        public DateTimeOffset? ClosedAt { get; internal set; }
    }

    private bool Counts(Ticket t, DateTimeOffset now) =>
        now - t.OpenedAt < Window && ((t.ClosedAt is { } closed && closed - t.OpenedAt <= Free) || (t.ClosedAt is null && now - t.OpenedAt <= Free));

    /// <summary>
    /// Seconds until the grant may open again; 0 when it may now. Asked before anything is dialled, so a refused request
    /// counts for nothing.
    /// </summary>
    public int RetryAfter(string account, string id)
    {
        lock (_lock)
        {
            var now = _time.GetUtcNow();
            _opens.RemoveAll(t => now - t.OpenedAt >= Window);
            var counted = _opens.Where(t => Counts(t, now)).ToList();
            var mine = counted.Where(t => t.Account == account && t.Id == id).ToList();
            if (mine.Count < CapFor && counted.Count < TotalCap) return 0;
            var blocking = mine.Count >= CapFor ? mine : counted;
            var oldest = blocking.Min(t => t.OpenedAt);
            return Math.Max(1, (int)Math.Ceiling((oldest + Window - now).TotalSeconds));
        }
    }

    /// <summary>
    /// Takes an open for the grant now, or says how many seconds until one may be taken: checking and taking under one
    /// lock, so two requests at once can't both pass. <see cref="Cancel"/> gives it back if nothing was reached.
    /// </summary>
    public Ticket? TryReserve(string account, string id, out int retryAfter)
    {
        lock (_lock)
        {
            retryAfter = RetryAfter(account, id);
            if (retryAfter > 0) return null;
            var ticket = new Ticket(account, id, _time.GetUtcNow());
            _opens.Add(ticket);
            return ticket;
        }
    }

    /// <summary>A reserved open reached nothing (refused before <c>rdpReady</c>): it doesn't count.</summary>
    public void Cancel(Ticket ticket)
    {
        lock (_lock) _opens.Remove(ticket);
    }

    public void Closed(Ticket ticket)
    {
        lock (_lock) ticket.ClosedAt ??= _time.GetUtcNow();
    }
}

/// <summary>Views of the screen at once: 2 a phone, 4 in all (ShellListener.swift's ScreenViewLimit), shared by every path.</summary>
public sealed class ScreenViewLimit
{
    public const int PerPhone = 2, Total = 4;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, int> _views = [];

    public bool TryTake(string phoneId)
    {
        lock (_lock)
        {
            if (_views.Values.Sum() >= Total || _views.GetValueOrDefault(phoneId) >= PerPhone) return false;
            _views[phoneId] = _views.GetValueOrDefault(phoneId) + 1;
            return true;
        }
    }

    public void Release(string phoneId)
    {
        lock (_lock)
        {
            if (_views.TryGetValue(phoneId, out var n)) { if (n <= 1) _views.Remove(phoneId); else _views[phoneId] = n - 1; }
        }
    }

    public int Count(string phoneId)
    {
        lock (_lock) return _views.GetValueOrDefault(phoneId);
    }
}
