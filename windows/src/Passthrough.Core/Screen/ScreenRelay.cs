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

    public static async Task<(long AToB, long BToA)> RunAsync(Stream a, Stream b, CancellationToken cancel = default)
    {
        using var done = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        long aToB = 0, bToA = 0;
        async Task Pump(Stream from, Stream to, bool forward)
        {
            var buffer = System.Buffers.ArrayPool<byte>.Shared.Rent(BufferSize);
            try
            {
                while (true)
                {
                    var n = await from.ReadAsync(buffer.AsMemory(0, BufferSize), done.Token).ConfigureAwait(false);
                    if (n == 0) break;
                    await to.WriteAsync(buffer.AsMemory(0, n), done.Token).ConfigureAwait(false);
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
        a.Dispose();
        b.Dispose();
        return (Interlocked.Read(ref aToB), Interlocked.Read(ref bToA));
    }
}
