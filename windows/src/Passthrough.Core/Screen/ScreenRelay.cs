namespace Passthrough.Core.Screen;

/// <summary>Whether the relay may go ahead (<see cref="Port"/>), or why not, in <c>rdp_unavailable</c>'s words.</summary>
public sealed record RelayVerdict(int? Port, string? Unavailable)
{
    public static RelayVerdict Ready(int port) => new(port, null);
    public static RelayVerdict No(string detail) => new(null, detail);
}

/// <summary>What the relay asks of this PC's Remote Desktop, in the service (stage 5 plan, section 4).</summary>
public interface IRemoteDesktopGate
{
    /// <summary>Remote Desktop may be relayed to for this account now: the facts, the exposure check, the port read now.</summary>
    Task<RelayVerdict> CheckAsync(string? account, CancellationToken cancel);

    /// <summary>
    /// A connection to Remote Desktop on <c>127.0.0.1:port</c>, its far end checked to be Windows' Remote Desktop
    /// service (the TCP table's owner of the other end equals TermService's process) before any byte passes. Null when it
    /// isn't, or nothing answered.
    /// </summary>
    Task<Stream?> DialAsync(int port, CancellationToken cancel);

    /// <summary>The lowercase hex SHA-256 of the certificate Remote Desktop presents; null when it can't be known.</summary>
    Task<string?> CertificateSha256Async(CancellationToken cancel);
}

/// <summary>A view, as the log and the after-view notice see it.</summary>
public sealed record RelayRecord(string PhoneId, string Label, string? Account, string Path, DateTimeOffset Start)
{
    public DateTimeOffset? End { get; init; }
    public long BytesOut { get; init; }
    public long BytesIn { get; init; }
    public string? EndedBy { get; init; }
}

/// <summary>
/// Two streams joined (a port of Splice.swift): each direction pumped through a 256 KiB buffer, failure taken from
/// reads and writes only, and either end finishing ends both. Returns the bytes each way.
/// </summary>
public static class Splice
{
    public const int BufferSize = 256 << 10;

    /// <summary>
    /// What a splice did since the last report: bytes each way, how long writes to <c>a</c> (the phone) were waited on,
    /// the longest single such wait, and the longest silence from <c>a</c>. For a view's periodic log line.
    /// </summary>
    public readonly record struct Progress(long FromA, long ToA, TimeSpan BlockedToA, TimeSpan LongestWriteToA, TimeSpan LongestQuietFromA, TimeSpan Held = default);

    /// <summary>Above this round trip over a relay, what goes to the viewer waits: the queue on the way is kept to about this much.</summary>
    public static readonly TimeSpan PaceAbove = TimeSpan.FromMilliseconds(600);
    /// <summary>The longest one write is held: a path that stays slow still gets the picture, late, and each write brings a new measurement.</summary>
    public static readonly TimeSpan PaceLimit = TimeSpan.FromMilliseconds(1500);

    /// <summary>
    /// Waits while <paramref name="roundTrip"/> says the relay's queue is long (above <see cref="PaceAbove"/>), up to
    /// <see cref="PaceLimit"/>; returns how long it waited. Only what goes to the viewer is held, never its input.
    /// </summary>
    public static async ValueTask<TimeSpan> PaceAsync(Func<TimeSpan?> roundTrip, TimeProvider time, CancellationToken cancel)
    {
        if (roundTrip() is not { } first || first <= PaceAbove) return TimeSpan.Zero;
        var started = time.GetTimestamp();
        while (time.GetElapsedTime(started) < PaceLimit)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(50), time, cancel).ConfigureAwait(false);
            if (roundTrip() is not { } now || now <= PaceAbove) break;
        }
        return time.GetElapsedTime(started);
    }

    public static async Task<(long AToB, long BToA)> RunAsync(Stream a, Stream b, CancellationToken cancel = default,
        Action<Progress>? report = null, TimeSpan? every = null, Func<TimeSpan?>? roundTripToA = null, TimeProvider? time = null)
    {
        long heldTicks = 0;
        using var done = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        long aToB = 0, bToA = 0;
        long blockedTicks = 0, longestWrite = 0, longestQuiet = 0, lastFromA = System.Diagnostics.Stopwatch.GetTimestamp();
        static void Max(ref long slot, long value) { long seen; while (value > (seen = Interlocked.Read(ref slot)) && Interlocked.CompareExchange(ref slot, value, seen) != seen) { } }
        async Task Report()
        {
            long lastA = 0, lastB = 0;
            try
            {
                while (true)
                {
                    await Task.Delay(every ?? TimeSpan.FromSeconds(5), done.Token).ConfigureAwait(false);
                    var (nowA, nowB) = (Interlocked.Read(ref aToB), Interlocked.Read(ref bToA));
                    var quiet = Math.Max(Interlocked.Exchange(ref longestQuiet, 0), System.Diagnostics.Stopwatch.GetTimestamp() - Interlocked.Read(ref lastFromA));
                    report!(new Progress(nowA - lastA, nowB - lastB,
                        System.Diagnostics.Stopwatch.GetElapsedTime(0, Interlocked.Exchange(ref blockedTicks, 0)),
                        System.Diagnostics.Stopwatch.GetElapsedTime(0, Interlocked.Exchange(ref longestWrite, 0)),
                        System.Diagnostics.Stopwatch.GetElapsedTime(0, quiet), TimeSpan.FromTicks(Interlocked.Exchange(ref heldTicks, 0))));
                    (lastA, lastB) = (nowA, nowB);
                }
            }
            catch (OperationCanceledException) { }
        }
        var reporting = report is null ? Task.CompletedTask : Report();
        async Task Pump(Stream from, Stream to, bool forward)
        {
            var buffer = System.Buffers.ArrayPool<byte>.Shared.Rent(BufferSize);
            try
            {
                while (true)
                {
                    var n = await from.ReadAsync(buffer.AsMemory(0, BufferSize), done.Token).ConfigureAwait(false);
                    if (n == 0) break;
                    if (!forward && roundTripToA is not null)
                        Interlocked.Add(ref heldTicks, (await PaceAsync(roundTripToA, time ?? TimeProvider.System, done.Token).ConfigureAwait(false)).Ticks);
                    var started = System.Diagnostics.Stopwatch.GetTimestamp();
                    if (forward)
                    {
                        Max(ref longestQuiet, started - Interlocked.Exchange(ref lastFromA, started));
                    }
                    await to.WriteAsync(buffer.AsMemory(0, n), done.Token).ConfigureAwait(false);
                    if (!forward)
                    {
                        var took = System.Diagnostics.Stopwatch.GetTimestamp() - started;
                        Interlocked.Add(ref blockedTicks, took);
                        Max(ref longestWrite, took);
                    }
                    if (forward) Interlocked.Add(ref aToB, n); else Interlocked.Add(ref bToA, n);
                }
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
            finally
            {
                System.Buffers.ArrayPool<byte>.Shared.Return(buffer);
                // End together: one side finishing ends the other.
                done.Cancel();
            }
        }
        await Task.WhenAll(Pump(a, b, true), Pump(b, a, false)).ConfigureAwait(false);
        await reporting.ConfigureAwait(false);
        a.Dispose();
        b.Dispose();
        return (Interlocked.Read(ref aToB), Interlocked.Read(ref bToA));
    }
}
