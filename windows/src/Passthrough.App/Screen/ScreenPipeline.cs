using System.Buffers;
using System.Threading.Channels;
using Passthrough.Core.Screen;
using Passthrough.Media;

namespace Passthrough.App.Screen;

/// <summary>A picture ready to show: BGRA, width × 4 bytes a row, in a pooled buffer; and the frame to ack once shown.</summary>
internal sealed class Picture(int width, int height, byte[] bgra, uint number) : IDisposable
{
    private byte[]? _bgra = bgra;
    public int Width { get; } = width;
    public int Height { get; } = height;
    public uint Number { get; } = number;
    public byte[] Bgra => _bgra ?? throw new ObjectDisposedException(nameof(Picture));
    public int Length => Width * Height * 4;
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _bgra, null) is { } b) ArrayPool<byte>.Shared.Return(b);
    }
}

/// <summary>What the pipeline tells the window, on the window's thread.</summary>
internal interface IScreenView
{
    void Sized(int width, int height);
    /// <summary>A newer picture is in the mailbox: take it with <see cref="ScreenPipeline.TakePicture"/>.</summary>
    void PictureReady();
    void Cursor(double x, double y, bool visible);
    void CursorShape(int width, int height, int hotX, int hotY, byte[] png);
    void Viewers(IReadOnlyList<string> names);
    void MovedAway(string to);
    void Copied(ScreenCopyResult result);
    void StreamClosed(Exception? error);
}

/// <summary>
/// From the stream to the window (stage 8 b2): the client's read loop hands frames to a bounded queue (8 frames or 32 MiB:
/// past it everything waiting is acked and dropped and a keyframe asked for); a decode thread of its own decodes,
/// converts to BGRA and puts the picture in a one-slot mailbox (a newer one replaces one not yet shown, which is acked
/// then); the window takes the newest and acks it once it is drawn. Every frame gets exactly one ack. Decoder failures
/// flush and ask for a keyframe; three in 10 s end the view with a <see cref="DecodeException"/>.
/// </summary>
internal sealed class ScreenPipeline : IScreenSink, IDisposable
{
    private const int MaxQueued = 8;
    private const long MaxQueuedBytes = 32 << 20;
    private static readonly TimeSpan FailureWindow = TimeSpan.FromSeconds(10);

    private abstract record Item;
    private sealed record FormatItem(ScreenCodec Codec, int Width, int Height, bool FullRange) : Item;
    private sealed record FrameItem(uint Number, bool Keyframe, System.Buffers.IMemoryOwner<byte> Data) : Item;

    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui;
    private readonly IScreenView _view;
    private readonly Channel<Item> _queue = Channel.CreateUnbounded<Item>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Lock _lock = new();
    private readonly Queue<DateTimeOffset> _failures = new();
    private readonly Thread _decodeThread;
    private ScreenVideoClient? _client;
    private int _queuedFrames;
    private long _queuedBytes;
    private Picture? _mailbox;
    private bool _presentPosted;
    private volatile bool _closed;

    public ScreenPipeline(Microsoft.UI.Dispatching.DispatcherQueue ui, IScreenView view)
    {
        _ui = ui;
        _view = view;
        _decodeThread = new Thread(DecodeLoop) { IsBackground = true, Name = "Passthrough screen decode" };
        _decodeThread.SetApartmentState(ApartmentState.MTA);
        _decodeThread.Start();
    }

    public void Attach(ScreenVideoClient client) => _client = client;

    private FormatItem? _latestFormat;
    private bool _formatQueued;

    private void Post(Action action) => OnUi(() => { if (!_closed) action(); });

    /// <summary>On the window's thread; what is thrown there is logged and closes the view, instead of ending the app with no trace.</summary>
    private void OnUi(Action action) => _ui.TryEnqueue(() =>
    {
        try { action(); }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Platform.LogFile.Error(e);
            Platform.LogFile.Flush();
            try { _view.StreamClosed(new DecodeException("The picture couldn't be drawn.", e)); }
            catch (Exception again) when (again is not OutOfMemoryException) { Platform.LogFile.Error(again); }
        }
    });

    // MARK: IScreenSink (the read loop)

    public void Format(ScreenCodec codec, int width, int height, IReadOnlyList<byte[]> parameterSets)
    {
        var fullRange = codec == ScreenCodec.H264 && H264Sps.TryParse(parameterSets[0])?.FullRange == true;
        // Format changes waiting to be decoded are merged into the newest: a Mac sending them faster than the decoder
        // is rebuilt can't queue them, or GPU devices, without end.
        bool queued;
        lock (_lock)
        {
            _latestFormat = new FormatItem(codec, width, height, fullRange);
            queued = _formatQueued;
            _formatQueued = true;
        }
        if (!queued) _queue.Writer.TryWrite(_latestFormat);
        Post(() => _view.Sized(width, height));
    }

    public void Frame(uint number, bool keyframe, System.Buffers.IMemoryOwner<byte> annexB)
    {
        bool overflow;
        lock (_lock)
        {
            overflow = _queuedFrames >= MaxQueued || _queuedBytes + annexB.Memory.Length > MaxQueuedBytes;
            if (!overflow)
            {
                _queuedFrames++;
                _queuedBytes += annexB.Memory.Length;
            }
        }
        if (!overflow)
        {
            _queue.Writer.TryWrite(new FrameItem(number, keyframe, annexB));
            return;
        }
        // Too far behind: drop what waits (each acked), and start again from a keyframe.
        annexB.Dispose();
        _client?.Shown(number);
        _dropUntilKeyframe = true;
        _client?.RequestKeyframe();
    }

    private volatile bool _dropUntilKeyframe;

    public void Fitted(ScreenFit fit) { }
    public void Cursor(double x, double y, bool visible) => Post(() => _view.Cursor(x, y, visible));
    public void CursorShape(int width, int height, int hotX, int hotY, ReadOnlyMemory<byte> png)
    {
        var copy = png.ToArray();
        Post(() => _view.CursorShape(width, height, hotX, hotY, copy));
    }
    public void Viewers(IReadOnlyList<string> names) => Post(() => _view.Viewers(names));
    public void MovedAway(string to) => Post(() => _view.MovedAway(to));
    public void Copied(ScreenCopyResult result) => Post(() => _view.Copied(result));
    public void SoundState(ScreenSoundState state) { }
    public void SoundPacket(ReadOnlyMemory<byte> packet) { }
    public void MicrophoneState(ScreenMicrophoneState state) { }

    public void Closed(Exception? error)
    {
        _queue.Writer.TryComplete();
        OnUi(() => _view.StreamClosed(error));
    }

    // MARK: Decoding

    private void DecodeLoop()
    {
        VideoDecoder? decoder = null;
        var fullRange = false;
        try
        {
            while (_queue.Reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
                while (_queue.Reader.TryRead(out var item))
                {
                    switch (item)
                    {
                        case FormatItem:
                            FormatItem f;
                            lock (_lock)
                            {
                                f = _latestFormat!;
                                _formatQueued = false;
                            }
                            decoder?.Dispose();
                            decoder = null;
                            fullRange = f.FullRange;
                            try { decoder = new VideoDecoder(f.Codec, f.Width, f.Height); }
                            catch (DecodeException e) { Fail(e); return; }
                            break;
                        case FrameItem frame:
                            lock (_lock)
                            {
                                _queuedFrames--;
                                _queuedBytes -= frame.Data.Memory.Length;
                            }
                            using (frame.Data)
                            {
                                if (_dropUntilKeyframe && !frame.Keyframe) { _client?.Shown(frame.Number); break; }
                                _dropUntilKeyframe = false;
                                if (decoder is null) { _client?.Shown(frame.Number); break; }
                                Decode(decoder, frame, fullRange);
                            }
                            break;
                    }
                }
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Platform.LogFile.Error(e);
            Platform.LogFile.Flush();
            Fail(e);
        }
        finally
        {
            decoder?.Dispose();
            // Whatever is still queued is acked, so nothing is left owed.
            while (_queue.Reader.TryRead(out var rest))
                if (rest is FrameItem f) { f.Data.Dispose(); _client?.Shown(f.Number); }
        }
    }

    private void Decode(VideoDecoder decoder, FrameItem frame, bool fullRange)
    {
        IReadOnlyList<Nv12Frame> pictures;
        try { pictures = decoder.Decode(frame.Data.Memory.Span, frame.Number, frame.Keyframe); }
        catch (DecodeException e)
        {
            _client?.Shown(frame.Number);
            var now = DateTimeOffset.UtcNow;
            _failures.Enqueue(now);
            while (_failures.Count > 0 && now - _failures.Peek() > FailureWindow) _failures.Dequeue();
            if (_failures.Count >= 3) { Fail(new DecodeException("This PC couldn't decode the picture.", e)); return; }
            decoder.Flush();
            _dropUntilKeyframe = true;
            _client?.RequestKeyframe();
            return;
        }
        if (pictures.Count == 0) { _client?.Shown(frame.Number); return; }
        for (var i = 0; i < pictures.Count; i++)
        {
            using var nv12 = pictures[i];
            var length = nv12.Width * nv12.Height * 4;
            var bgra = ArrayPool<byte>.Shared.Rent(length);
            Nv12ToBgra.Convert(nv12, bgra.AsSpan(0, length), nv12.Width * 4, fullRange);
            // Only the last picture carries this frame's ack; earlier ones (rare) are shown or dropped unacked.
            Put(new Picture(nv12.Width, nv12.Height, bgra, i == pictures.Count - 1 ? frame.Number : 0));
        }
    }

    private void Put(Picture picture)
    {
        Picture? replaced;
        bool post;
        lock (_lock)
        {
            replaced = _mailbox;
            _mailbox = picture;
            post = !_presentPosted;
            _presentPosted = true;
        }
        if (replaced is not null)
        {
            if (replaced.Number != 0) _client?.Shown(replaced.Number);
            replaced.Dispose();
        }
        if (post) Post(_view.PictureReady);
    }

    /// <summary>The newest picture (the window draws it, then calls <see cref="Shown"/> and disposes it); null when none.</summary>
    public Picture? TakePicture()
    {
        lock (_lock)
        {
            _presentPosted = false;
            var p = _mailbox;
            _mailbox = null;
            return p;
        }
    }

    public void Shown(Picture picture)
    {
        if (picture.Number != 0) _client?.Shown(picture.Number);
    }

    private void Fail(Exception e)
    {
        OnUi(() => _view.StreamClosed(e));
        if (_client is { } c) _ = c.DisposeAsync().AsTask();
    }

    public void Dispose()
    {
        _closed = true;
        _queue.Writer.TryComplete();
        lock (_lock)
        {
            _mailbox?.Dispose();
            _mailbox = null;
        }
    }
}
