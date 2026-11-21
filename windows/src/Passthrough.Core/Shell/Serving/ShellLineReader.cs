namespace Passthrough.Core.Shell.Serving;

/// <summary>
/// Newline-delimited lines off a stream, each at most <see cref="Limit"/> bytes: a longer one is a protocol error, not a
/// buffer that grows. The limit can be raised once the peer has proved itself. Empty lines are skipped. One reader at a time.
/// </summary>
public sealed class ShellLineReader(Stream stream, int limit)
{
    private byte[] _buffer = new byte[Math.Min(limit + 1, 16 * 1024)];
    private int _start, _count;

    public int Limit { get; set; } = limit;

    /// <summary>Bytes read off the stream that no line has taken yet (a phone sent more than it should have).</summary>
    public bool HasBuffered => _count > 0;

    /// <summary>The next line, without its newline; null once the stream ends between lines.</summary>
    public async Task<byte[]?> ReadLineAsync(CancellationToken ct = default)
    {
        while (true)
        {
            var newline = Array.IndexOf(_buffer, (byte)'\n', _start, _count);
            if (newline >= 0)
            {
                var length = newline - _start;
                var line = _buffer.AsSpan(_start, length).ToArray();
                _start = newline + 1;
                _count -= length + 1;
                if (length > Limit) throw new LineTooLongException();
                if (length == 0) continue;
                return line;
            }
            if (_count > Limit) throw new LineTooLongException();
            if (_start > 0)
            {
                Buffer.BlockCopy(_buffer, _start, _buffer, 0, _count);
                _start = 0;
            }
            if (_count == _buffer.Length) Array.Resize(ref _buffer, Math.Min(_buffer.Length * 2, Limit + 2));
            var read = await stream.ReadAsync(_buffer.AsMemory(_count), ct).ConfigureAwait(false);
            if (read == 0) return null;
            _count += read;
        }
    }
}

public sealed class LineTooLongException() : IOException("a line was longer than allowed");
