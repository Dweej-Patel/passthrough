namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// A clock that moves only when told to. <see cref="Advance"/> fires every timer that falls due on the way,
/// in time order, with the clock set to each timer's due time while its callback runs (so a 5 s periodic
/// timer fires four times over a 21 s advance). Timers made by <c>Task.Delay(TimeSpan, TimeProvider)</c>
/// and <c>CancellationTokenSource(TimeSpan, TimeProvider)</c> go through <see cref="CreateTimer"/> too.
/// </summary>
public sealed class FakeTimeProvider : TimeProvider
{
    private readonly Lock _gate = new();
    private readonly List<FakeTimer> _timers = [];
    private DateTimeOffset _now;

    public FakeTimeProvider() : this(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)) { }

    public FakeTimeProvider(DateTimeOffset start) { _now = start; }

    public override DateTimeOffset GetUtcNow()
    {
        lock (_gate) return _now;
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    /// <summary>Timestamps are ticks of the fake clock, so <c>GetElapsedTime</c> follows it.</summary>
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override long GetTimestamp()
    {
        lock (_gate) return _now.UtcTicks;
    }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new FakeTimer(this, callback, state);
        timer.Change(dueTime, period);
        return timer;
    }

    /// <summary>How long until each armed timer fires next, soonest first.</summary>
    public IReadOnlyList<TimeSpan> DueIn()
    {
        lock (_gate) return [.. _timers.Where(t => t.Due is not null).Select(t => t.Due!.Value - _now).Order()];
    }

    /// <summary>Moves the clock forward by <paramref name="by"/>, firing due timers in order. Callbacks run on the caller's thread.</summary>
    public void Advance(TimeSpan by)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(by, TimeSpan.Zero);
        DateTimeOffset target;
        lock (_gate) target = _now + by;
        while (true)
        {
            FakeTimer? next;
            lock (_gate)
            {
                next = _timers.Where(t => t.Due is { } due && due <= target).MinBy(t => t.Due);
                if (next is null)
                {
                    _now = target;
                    return;
                }
                _now = next.Due!.Value;
                next.Due = next.Period is { } period && period > TimeSpan.Zero ? _now + period : null;
            }
            next.Fire();
        }
    }

    private sealed class FakeTimer(FakeTimeProvider owner, TimerCallback callback, object? state) : ITimer
    {
        /// <summary>When it fires next; null while stopped. Guarded by the owner's lock.</summary>
        public DateTimeOffset? Due { get; set; }
        public TimeSpan? Period { get; private set; }
        private bool _disposed;

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            lock (owner._gate)
            {
                if (_disposed) return false;
                if (!owner._timers.Contains(this)) owner._timers.Add(this);
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : owner._now + dueTime;
                Period = period == Timeout.InfiniteTimeSpan ? null : period;
            }
            return true;
        }

        public void Fire() => callback(state);

        public void Dispose()
        {
            lock (owner._gate)
            {
                _disposed = true;
                owner._timers.Remove(this);
            }
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
