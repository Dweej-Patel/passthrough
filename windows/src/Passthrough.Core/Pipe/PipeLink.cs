using System.Threading.Channels;

namespace Passthrough.Core.Pipe;

/// <summary>
/// One end of the pipe once the handshake is done: one writer task fed by a queue, so no caller ever waits on the pipe,
/// and a reader handing each frame on in order. A side that lets more than <see cref="MaxQueued"/> bytes pile up for
/// the other (it isn't reading) is cut off; so is a side that says nothing for <see cref="Silence"/> (each side pings
/// after <see cref="PingAfter"/> of quiet).
/// </summary>
public sealed class PipeLink : IAsyncDisposable
{
    public static readonly TimeSpan PingAfter = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan Silence = TimeSpan.FromSeconds(30);

    private readonly Stream _stream;
    private readonly byte _ping, _pong, _peerPing, _peerPong;
    private readonly TimeProvider _time;
    private readonly Action<string>? _log;
    private readonly Channel<(byte[] Bytes, Action<int>? Written)> _outgoing =
        Channel.CreateUnbounded<(byte[], Action<int>?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _closing = new();
    private long _queued;
    private long _lastHeard;
    private int _closed;

    /// <param name="service">This end is the service's (its pings are 0x4E/0x4F; the tray app's 0x1E/0x1F).</param>
    public PipeLink(Stream stream, bool service, long maxQueued, TimeProvider? time = null, Action<string>? log = null)
    {
        _stream = stream;
        (_ping, _pong, _peerPing, _peerPong) = service
            ? (PipeKind.ServicePing, PipeKind.ServicePong, PipeKind.TrayPing, PipeKind.TrayPong)
            : (PipeKind.TrayPing, PipeKind.TrayPong, PipeKind.ServicePing, PipeKind.ServicePong);
        MaxQueued = maxQueued;
        _time = time ?? TimeProvider.System;
        _log = log;
        _lastHeard = _time.GetTimestamp();
    }

    public long MaxQueued { get; }

    /// <summary>Bytes waiting to be written.</summary>
    public long Queued => Interlocked.Read(ref _queued);

    public bool IsClosed => Volatile.Read(ref _closed) == 1;

    /// <summary>Cancelled when the link closes.</summary>
    public CancellationToken Closing => _closing.Token;

    /// <summary>
    /// Queues a frame; <paramref name="written"/> runs with its size once it is written (or dropped with the link).
    /// False when the link is closed, or now closes because the other side stopped reading.
    /// </summary>
    public bool Send(PipeFrame frame, Action<int>? written = null)
    {
        if (IsClosed) return false;
        var bytes = frame.Encode();
        if (Interlocked.Add(ref _queued, bytes.Length) > MaxQueued)
        {
            _log?.Invoke("pipe: the other side isn't reading; closing");
            Close();
            written?.Invoke(bytes.Length);
            return false;
        }
        if (_outgoing.Writer.TryWrite((bytes, written))) return true;
        written?.Invoke(bytes.Length);
        return false;
    }

    /// <summary>Writes, reads and pings until the link closes; every frame but pings goes to <paramref name="onFrame"/>, in order.</summary>
    public async Task RunAsync(Func<PipeFrame, ValueTask> onFrame)
    {
        var writer = WriteAllAsync();
        using var pinger = _time.CreateTimer(_ => Tick(), null, PingAfter, PingAfter);
        var reader = new PipeFrameReader(_stream);
        try
        {
            while (!IsClosed && await reader.ReadAsync(_closing.Token).ConfigureAwait(false) is { } frame)
            {
                Interlocked.Exchange(ref _lastHeard, _time.GetTimestamp());
                if (frame.Kind == _peerPing) { Send(new PipeFrame(_pong, ReadOnlyMemory<byte>.Empty)); continue; }
                if (frame.Kind == _peerPong) continue;
                await onFrame(frame).ConfigureAwait(false);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
        Close();
        await writer.ConfigureAwait(false);
    }

    private void Tick()
    {
        var quiet = _time.GetElapsedTime(Interlocked.Read(ref _lastHeard));
        if (quiet >= Silence)
        {
            _log?.Invoke("pipe: the other side went quiet; closing");
            Close();
        }
        else if (quiet >= PingAfter) Send(new PipeFrame(_ping, ReadOnlyMemory<byte>.Empty));
    }

    private async Task WriteAllAsync()
    {
        try
        {
            await foreach (var (bytes, written) in _outgoing.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                await _stream.WriteAsync(bytes, _closing.Token).ConfigureAwait(false);
                Interlocked.Add(ref _queued, -bytes.Length);
                written?.Invoke(bytes.Length);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { Close(); }
        while (_outgoing.Reader.TryRead(out var left))
        {
            Interlocked.Add(ref _queued, -left.Bytes.Length);
            left.Written?.Invoke(left.Bytes.Length);
        }
    }

    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _outgoing.Writer.TryComplete();
        _closing.Cancel();
        _stream.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Close();
        return ValueTask.CompletedTask;
    }
}
