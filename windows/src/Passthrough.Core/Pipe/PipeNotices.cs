namespace Passthrough.Core.Pipe;

/// <summary>
/// Something the person at the PC should know, from the service, that stays until they answer it (stage 5 plan,
/// sections 3 and 5; stage 7 a.8): the screen was used, a phone was just given access, a computer was given access,
/// Remote Desktop is open to the network.
/// </summary>
public sealed record PipeNotice
{
    public const string Viewed = "viewed", Granted = "granted", ComputerGranted = "computerGranted", ComputerScreenPending = "computerScreenPending",
        Exposed = "exposed";

    public string Id { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Text { get; init; } = "";
    /// <summary>The phone or computer it is about, for its buttons (Allow screen, Revoke).</summary>
    public string? Subject { get; init; }
    public long At { get; init; }
}

/// <summary>
/// The notices for each account, in the service: at most 20 an account (the oldest go), each until the account's
/// tray app answers it. Views by the same phone less than 5 minutes apart are one notice; an exposure notice is one
/// for the whole PC and goes by itself once the check passes. Another account never sees a notice that names someone
/// else's phone.
/// </summary>
public sealed class NoticeBoard(TimeProvider? time = null)
{
    public const int PerAccount = 20;
    private static readonly TimeSpan JoinViews = TimeSpan.FromMinutes(5);
    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, List<(PipeNotice Notice, DateTimeOffset Start, DateTimeOffset End)>> _byAccount = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Fires with the account whose notices changed (<c>null</c>: every account's, the exposure notice).</summary>
    public event Action<string?>? Changed;

    public IReadOnlyList<PipeNotice> For(string account)
    {
        lock (_lock) return _byAccount.TryGetValue(account, out var list) ? [.. list.Select(n => n.Notice)] : [];
    }

    public void Add(string account, string kind, string text, string? subject = null)
    {
        lock (_lock) Put(account, new PipeNotice { Id = Guid.NewGuid().ToString("N"), Kind = kind, Text = text, Subject = subject, At = _time.GetUtcNow().ToUnixTimeSeconds() }, default, default);
        Changed?.Invoke(account);
    }

    /// <summary>
    /// A view of the screen ended: "<paramref name="label"/> used this PC's screen, 14:02 to 14:20." One under 10 s makes
    /// none (a failed sign-in moves no windows).
    /// </summary>
    public void Viewed(string account, string phoneId, string label, DateTimeOffset start, DateTimeOffset end, Func<DateTimeOffset, string> clock)
    {
        if (end - start < TimeSpan.FromSeconds(10)) return;
        lock (_lock)
        {
            if (_byAccount.TryGetValue(account, out var list)
                && list.FindIndex(n => n.Notice.Kind == PipeNotice.Viewed && n.Notice.Subject == phoneId && start - n.End < JoinViews) is var i and >= 0)
            {
                var earlier = list[i];
                list[i] = (earlier.Notice with { Text = ViewedText(label, earlier.Start, end, clock), At = _time.GetUtcNow().ToUnixTimeSeconds() }, earlier.Start, end);
            }
            else
            {
                Put(account, new PipeNotice
                {
                    Id = Guid.NewGuid().ToString("N"), Kind = PipeNotice.Viewed, Text = ViewedText(label, start, end, clock), Subject = phoneId,
                    At = _time.GetUtcNow().ToUnixTimeSeconds(),
                }, start, end);
            }
        }
        Changed?.Invoke(account);
    }

    internal static string ViewedText(string label, DateTimeOffset start, DateTimeOffset end, Func<DateTimeOffset, string> clock) =>
        $"{label} used this PC's screen, {clock(start)} to {clock(end)}. Your windows may have moved.";

    /// <summary>Remote Desktop is open to the network (or not any more): one notice on every account's list, gone when it closes.</summary>
    public void Exposed(IEnumerable<string> accounts, string? reason)
    {
        var changed = false;
        lock (_lock)
        {
            foreach (var account in accounts)
            {
                var list = List(account);
                var had = list.RemoveAll(n => n.Notice.Kind == PipeNotice.Exposed) > 0;
                if (reason is not null)
                {
                    list.Add((new PipeNotice
                    {
                        Id = "exposed", Kind = PipeNotice.Exposed,
                        Text = $"Remote Desktop is open to the network, so Passthrough won't relay to it. {reason}",
                        At = _time.GetUtcNow().ToUnixTimeSeconds(),
                    }, default, default));
                    changed |= !had;
                }
                else changed |= had;
            }
        }
        if (changed) Changed?.Invoke(null);
    }

    /// <summary>The account answered it (OK, Allow screen, Revoke): it goes.</summary>
    public bool Answer(string account, string id)
    {
        bool removed;
        lock (_lock) removed = List(account).RemoveAll(n => n.Notice.Id == id && n.Notice.Kind != PipeNotice.Exposed) > 0;
        if (removed) Changed?.Invoke(account);
        return removed;
    }

    private List<(PipeNotice Notice, DateTimeOffset Start, DateTimeOffset End)> List(string account)
    {
        if (!_byAccount.TryGetValue(account, out var list)) _byAccount[account] = list = [];
        return list;
    }

    private void Put(string account, PipeNotice notice, DateTimeOffset start, DateTimeOffset end)
    {
        var list = List(account);
        list.Add((notice, start, end));
        while (list.Count > PerAccount) list.RemoveAt(list.FindIndex(n => n.Notice.Kind != PipeNotice.Exposed));
    }
}
