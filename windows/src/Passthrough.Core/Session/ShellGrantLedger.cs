namespace Passthrough.Core.Session;

/// <summary>
/// Which attached phones already hold a shell key with the current grant contents over this cable connection, so
/// channel retries don't hand out a fresh key each time while a change in what grants carry (certificate, port,
/// iroh endpoint, relay) still reaches the phone. One grant per device is in flight at a time; each confirmation
/// names the grant it answers. A phone that never answers is granted again with back-off, then slowly. A port of
/// <c>ShellGrantLedger</c> in MacSessionPolicy.swift; times come from the caller. Not thread-safe: it is used on
/// <see cref="HostSession"/>'s loop.
/// </summary>
public sealed class ShellGrantLedger
{
    /// <summary>How long a grant may wait for the phone's answer before it counts as lost.</summary>
    public static readonly TimeSpan AnswerTimeout = TimeSpan.FromSeconds(15);

    /// <summary>
    /// The wait before granting again after the 1st, 2nd, … consecutive unanswered grant (counted from the end of
    /// <see cref="AnswerTimeout"/>); after that <see cref="SlowRetryDelay"/> each time, until a new channel, a new
    /// pairing, a change in contents or an answer starts afresh.
    /// </summary>
    public static readonly IReadOnlyList<TimeSpan> RetryDelays =
        [TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(120)];

    /// <summary>The wait once <see cref="RetryDelays"/> are used up, so a phone briefly unable to store a key still gets one without a re-plug.</summary>
    public static readonly TimeSpan SlowRetryDelay = TimeSpan.FromSeconds(600);

    /// <summary>What happened to a grant whose answer did not come in time.</summary>
    public abstract record Expiry
    {
        private Expiry() { }

        /// <summary>The grant was answered, replaced or dropped meanwhile: nothing to do.</summary>
        public sealed record Stale : Expiry;

        /// <summary>Grant again after <paramref name="After"/>; <paramref name="FirstTimeout"/> starts a new streak.</summary>
        public sealed record Retry(TimeSpan After, bool FirstTimeout) : Expiry;
    }

    private sealed record InFlight(string Contents, string GrantId);
    private sealed record Backoff(string Contents, int Timeouts, DateTimeOffset NotBefore);

    private readonly Dictionary<string, string> _granted = [];
    private readonly Dictionary<string, InFlight> _inFlight = [];
    private readonly Dictionary<string, Backoff> _backoff = [];
    /// <summary>Devices whose access was just revoked: no grant until a new channel opens to them, or they pair anew.</summary>
    private readonly HashSet<string> _held = [];

    /// <summary>
    /// Whether to send a grant with these contents to this device now: not while one is in flight (re-check once it
    /// is answered), not while held, not when the phone already holds these contents, and not while backing off
    /// after unanswered grants of these same contents (other contents start afresh).
    /// </summary>
    public bool ShouldGrant(string deviceId, string contents, DateTimeOffset now)
    {
        if (_held.Contains(deviceId) || _inFlight.ContainsKey(deviceId)) return false;
        if (_granted.TryGetValue(deviceId, out var held) && held == contents) return false;
        return !(_backoff.TryGetValue(deviceId, out var b) && b.Contents == contents && now < b.NotBefore);
    }

    /// <summary>
    /// Whether the phone's answer, echoing <paramref name="echoedGrantId"/>, is for grant
    /// <paramref name="inFlightGrantId"/>. Phones that predate grant ids echo none; their answer is taken for the grant
    /// in flight (one per device).
    /// </summary>
    public static bool AnswerMatches(string? echoedGrantId, string inFlightGrantId) =>
        echoedGrantId is null || echoedGrantId == inFlightGrantId;

    public bool IsHeld(string deviceId) => _held.Contains(deviceId);

    /// <summary>The grant in flight to this device, if any.</summary>
    public string? InFlightGrantId(string deviceId) => _inFlight.TryGetValue(deviceId, out var p) ? p.GrantId : null;

    /// <summary>A grant went out and awaits the phone's answer.</summary>
    public void Sent(string deviceId, string contents, string grantId)
    {
        _inFlight[deviceId] = new InFlight(contents, grantId);
        if (_backoff.TryGetValue(deviceId, out var b) && b.Contents != contents) _backoff.Remove(deviceId);
    }

    /// <summary>The phone stored the key of grant <paramref name="grantId"/>. False (nothing recorded) when that grant is no longer the one in flight, e.g. it was revoked.</summary>
    public bool Confirmed(string deviceId, string grantId)
    {
        if (!_inFlight.TryGetValue(deviceId, out var pending) || pending.GrantId != grantId) return false;
        _inFlight.Remove(deviceId);
        _granted[deviceId] = pending.Contents;
        _backoff.Remove(deviceId);
        return true;
    }

    /// <summary>
    /// The answer to grant <paramref name="grantId"/> did not come in time. Unless that grant was answered, replaced or
    /// dropped meanwhile, the device may be granted again after a growing delay.
    /// </summary>
    public Expiry Expired(string deviceId, string grantId, DateTimeOffset now)
    {
        if (!_inFlight.TryGetValue(deviceId, out var pending) || pending.GrantId != grantId) return new Expiry.Stale();
        _inFlight.Remove(deviceId);
        var previous = _backoff.TryGetValue(deviceId, out var b) && b.Contents == pending.Contents ? b.Timeouts : 0;
        var timeouts = previous + 1;
        var delay = timeouts <= RetryDelays.Count ? RetryDelays[timeouts - 1] : SlowRetryDelay;
        _backoff[deviceId] = new Backoff(pending.Contents, timeouts, now + delay);
        return new Expiry.Retry(delay, timeouts == 1);
    }

    /// <summary>The control channel closed before the phone answered: try again on the next one.</summary>
    public void ChannelClosed(string deviceId) => _inFlight.Remove(deviceId);

    /// <summary>A new control channel to this device opened: a fresh start.</summary>
    public void ChannelOpened(string deviceId)
    {
        _held.Remove(deviceId);
        _backoff.Remove(deviceId);
    }

    /// <summary>This device paired anew: it gets a grant even after a revoke.</summary>
    public void Paired(string deviceId)
    {
        _held.Remove(deviceId);
        _backoff.Remove(deviceId);
    }

    /// <summary>The cable was unplugged: the next connection grants again.</summary>
    public void Detached(string deviceId)
    {
        _inFlight.Remove(deviceId);
        _granted.Remove(deviceId);
        _backoff.Remove(deviceId);
        _held.Remove(deviceId);
    }

    /// <summary>
    /// This device's shell access was revoked: forget its grants (an answer to one in flight is ignored) and send none
    /// until <see cref="ChannelOpened"/> or <see cref="Paired"/>. Other devices are untouched.
    /// </summary>
    public void Revoked(string deviceId)
    {
        _inFlight.Remove(deviceId);
        _granted.Remove(deviceId);
        _backoff.Remove(deviceId);
        _held.Add(deviceId);
    }

    /// <summary>Remote access was turned on again, or a pairing was forgotten.</summary>
    public void Reset()
    {
        _granted.Clear();
        _inFlight.Clear();
        _backoff.Clear();
        _held.Clear();
    }
}
