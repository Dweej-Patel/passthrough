using Passthrough.Core.Protocol;

namespace Passthrough.Core.Control;

/// <summary>
/// Newline-delimited JSON envelopes over a stream: the control channel's framing. Empty lines are skipped.
/// Not safe for concurrent reads or concurrent writes (one reader and one writer at a time is fine).
/// </summary>
public sealed class LineChannel(Stream stream) : IAsyncDisposable
{
    private const int InitialBuffer = 16 * 1024;

    private byte[] _buffer = new byte[InitialBuffer];
    private int _start;
    private int _count;

    /// <summary>
    /// The next envelope; null when the stream ends cleanly between lines. Throws <see cref="ProtocolException"/>
    /// for a line over <see cref="ProtocolConstants.MaxLineBytes"/>, a line that is not a control message, or a
    /// stream that ends mid-line.
    /// </summary>
    public async Task<ControlEnvelope?> ReadAsync(CancellationToken ct)
    {
        while (true)
        {
            var newline = Array.IndexOf(_buffer, (byte)'\n', _start, _count);
            if (newline >= 0)
            {
                var length = newline - _start;
                var line = _buffer.AsMemory(_start, length);
                _start = newline + 1;
                _count -= length + 1;
                if (length == 0) continue;
                if (length > ProtocolConstants.MaxLineBytes) throw TooLong();
                return ControlEnvelope.Decode(line.Span);
            }
            if (_count > ProtocolConstants.MaxLineBytes) throw TooLong();

            if (_start > 0)
            {
                Buffer.BlockCopy(_buffer, _start, _buffer, 0, _count);
                _start = 0;
            }
            if (_count == _buffer.Length)
                Array.Resize(ref _buffer, Math.Min(_buffer.Length * 2, ProtocolConstants.MaxLineBytes + 1));

            var read = await stream.ReadAsync(_buffer.AsMemory(_count), ct).ConfigureAwait(false);
            if (read == 0)
            {
                if (_count > 0) throw new ProtocolException("The control channel ended in the middle of a line");
                return null;
            }
            _count += read;
        }
    }

    public async Task WriteAsync(ControlEnvelope e, CancellationToken ct)
    {
        await stream.WriteAsync(e.EncodeLine(), ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public ValueTask DisposeAsync() => stream.DisposeAsync();

    private static ProtocolException TooLong() =>
        new($"A control line is longer than {ProtocolConstants.MaxLineBytes} bytes");
}
