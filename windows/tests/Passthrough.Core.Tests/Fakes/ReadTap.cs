namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// Wraps the stream a control client opens and tells how many lines the client has finished with. The client's reader
/// handles every complete line it holds before it asks the stream for more, so when a read starts, every line delivered
/// before it has been handled. A test waits on <see cref="LinesHandled"/> before it moves the clock, instead of
/// sleeping and hoping the client got there.
/// </summary>
public sealed class ReadTap
{
    private long _delivered;
    private long _handled;

    /// <summary>Lines delivered to the client before its latest read began: all of them handled.</summary>
    public long LinesHandled => Interlocked.Read(ref _handled);

    public Func<CancellationToken, Task<Stream>> Wrap(Func<CancellationToken, Task<Stream>> open) =>
        async ct => new TappedStream(this, await open(ct));

    private sealed class TappedStream(ReadTap tap, Stream inner) : Stream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            Interlocked.Exchange(ref tap._handled, Interlocked.Read(ref tap._delivered));
            var read = await inner.ReadAsync(buffer, ct);
            Interlocked.Add(ref tap._delivered, buffer.Span[..read].Count((byte)'\n'));
            return read;
        }

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => inner.WriteAsync(buffer, ct);
        public override Task FlushAsync(CancellationToken ct) => inner.FlushAsync(ct);

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => inner.Flush();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException("the client reads asynchronously");
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => inner.Write(buffer, offset, count);

        protected override void Dispose(bool disposing)
        {
            if (disposing) inner.Dispose();
            base.Dispose(disposing);
        }

        public override ValueTask DisposeAsync() => inner.DisposeAsync();
    }
}
