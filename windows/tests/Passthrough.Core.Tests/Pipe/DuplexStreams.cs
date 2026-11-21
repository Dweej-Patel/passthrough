using System.Threading.Channels;

namespace Passthrough.Core.Tests.Pipe;

/// <summary>Two connected in-memory streams, like a pipe's two ends: what one writes the other reads. Disposing either ends both.</summary>
internal static class DuplexStreams
{
    public static (Stream A, Stream B) Create()
    {
        var aToB = Channel.CreateUnbounded<byte[]>();
        var bToA = Channel.CreateUnbounded<byte[]>();
        var a = new End(bToA.Reader, aToB.Writer);
        var b = new End(aToB.Reader, bToA.Writer);
        a.Peer = b;
        b.Peer = a;
        return (a, b);
    }

    private sealed class End(ChannelReader<byte[]> inbound, ChannelWriter<byte[]> outbound) : Stream
    {
        private byte[] _current = [];
        private int _offset;
        private int _closed;
        public End? Peer;

        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _closed) == 1, this);
            while (_offset >= _current.Length)
            {
                try
                {
                    if (!await inbound.WaitToReadAsync(cancel)) return 0;
                }
                catch (ChannelClosedException) { return 0; }
                if (!inbound.TryRead(out var next)) continue;
                (_current, _offset) = (next, 0);
            }
            var n = Math.Min(buffer.Length, _current.Length - _offset);
            _current.AsMemory(_offset, n).CopyTo(buffer);
            _offset += n;
            return n;
        }

        public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancel = default)
        {
            if (Volatile.Read(ref _closed) == 1 || !outbound.TryWrite(buffer.ToArray())) throw new IOException("The other end is gone.");
            return ValueTask.CompletedTask;
        }

        protected override void Dispose(bool disposing)
        {
            if (Interlocked.Exchange(ref _closed, 1) == 1) return;
            outbound.TryComplete();
            Peer?.Dispose();
            base.Dispose(disposing);
        }
    }
}
