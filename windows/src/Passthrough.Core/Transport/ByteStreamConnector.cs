using System.Net.Sockets;

namespace Passthrough.Core.Transport;

public static class ByteStreamConnector
{
    /// <summary>Connects a TCP socket to <paramref name="host"/>:<paramref name="port"/>.</summary>
    public static StreamConnector Tcp(string host, int port) => async ct =>
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync(host, port, ct);
            return new OwnedTcpStream(client);
        }
        catch
        {
            client.Dispose();
            throw;
        }
    };

    /// <summary>A network stream that closes its socket when disposed.</summary>
    private sealed class OwnedTcpStream(TcpClient client) : Stream
    {
        private readonly NetworkStream _inner = client.GetStream();

        public override bool CanRead => _inner.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => _inner.CanWrite;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => _inner.Flush();
        public override Task FlushAsync(CancellationToken ct) => _inner.FlushAsync(ct);
        public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => _inner.ReadAsync(buffer, ct);
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => _inner.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => _inner.WriteAsync(buffer, ct);

        protected override void Dispose(bool disposing)
        {
            if (disposing) client.Dispose();
            base.Dispose(disposing);
        }
    }
}
