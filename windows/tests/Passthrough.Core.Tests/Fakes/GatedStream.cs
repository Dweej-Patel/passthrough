namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// Wraps a stream and holds back every write whose bytes match <paramref name="holds"/> until <see cref="Release"/>,
/// so a test can keep a message off the wire while the other side talks. Reads pass straight through.
/// </summary>
public sealed class GatedStream(Stream inner, Func<ReadOnlyMemory<byte>, bool> holds) : Stream
{
    private readonly TaskCompletionSource _released = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _held = new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>Completes once a write is being held.</summary>
    public Task Held => _held.Task;

    public bool IsDisposed { get; private set; }

    public void Release() => _released.TrySetResult();

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
    {
        if (holds(buffer))
        {
            _held.TrySetResult();
            await _released.Task.WaitAsync(ct);
        }
        await inner.WriteAsync(buffer, ct);
    }

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => inner.ReadAsync(buffer, ct);
    public override Task FlushAsync(CancellationToken ct) => inner.FlushAsync(ct);

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() => inner.Flush();
    public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => inner.Write(buffer, offset, count);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            IsDisposed = true;
            inner.Dispose();
        }
        base.Dispose(disposing);
    }
}
