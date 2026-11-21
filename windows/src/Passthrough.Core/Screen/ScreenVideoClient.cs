using System.Buffers;
using System.Buffers.Binary;
using System.Text;
using System.Threading.Channels;

namespace Passthrough.Core.Screen;

/// <summary>What a <see cref="ScreenVideoClient"/> hands on, on its read loop and in order.</summary>
public interface IScreenSink
{
    /// <summary>The stream's codec, size and parameter sets, checked (<see cref="ScreenVideoClient.CheckFormat"/>); only when one changed.</summary>
    void Format(ScreenCodec codec, int width, int height, IReadOnlyList<byte[]> parameterSets);
    /// <summary>
    /// A frame in Annex B with in-band parameter sets dropped (and, on a keyframe, the checked ones first). The sink owns
    /// <paramref name="annexB"/> and calls <see cref="ScreenVideoClient.Shown"/> once for it: when it is presented, superseded
    /// or couldn't be shown.
    /// </summary>
    void Frame(uint number, bool keyframe, IMemoryOwner<byte> annexB);
    void Fitted(ScreenFit fit);
    /// <summary>The Mac's pointer at (<paramref name="x"/>, <paramref name="y"/>), each 0…1 across the stream; or not on it.</summary>
    void Cursor(double x, double y, bool visible);
    /// <summary>The pointer's look: a PNG whose real size was read from its header and is 1…1024 a side; not decoded here.</summary>
    void CursorShape(int width, int height, int hotX, int hotY, ReadOnlyMemory<byte> png);
    void Viewers(IReadOnlyList<string> names);
    /// <summary>Another device took this view over; <see cref="Closed"/> follows when the Mac ends the stream.</summary>
    void MovedAway(string to);
    /// <summary>The answer to <see cref="ScreenVideoClient.CopySelection"/>, and only that.</summary>
    void Copied(ScreenCopyResult result);
    void SoundState(ScreenSoundState state);
    void SoundPacket(ReadOnlyMemory<byte> packet);
    void MicrophoneState(ScreenMicrophoneState state);
    /// <summary>Once: the stream is over. Null when <see cref="ScreenVideoClient.DisposeAsync"/> ended it.</summary>
    void Closed(Exception? error);
}

/// <summary>The connection carrying the screen ended (the Mac closed it, or the path went away).</summary>
public sealed class ScreenConnectionLostException(Exception? inner = null) : IOException("The connection was lost.", inner);

/// <summary>
/// The viewer's end of the Mac's own screen stream (a port of ScreenVideoClient.swift), over a stream the shell client
/// handed over after <c>screenVideoReady</c>. It says <c>hello</c> first, checks everything the Mac sends before handing it
/// on (sizes, parameter sets, NAL lengths, pointer images), and sends input in one ordered queue. Call
/// <see cref="Shown"/> for every frame handed on: the Mac paces what it sends to those acks.
/// </summary>
public sealed class ScreenVideoClient : IAsyncDisposable
{
    public const int MaxCursorSide = 1024;
    public const int MinStreamSide = 16;
    public const int MaxStreamSide = 4096;
    public const int MaxParameterSet = 4096;
    public const int ReadSize = 256 * 1024;
    /// <summary>Half a second of voice: past this much still unsent, more is left out.</summary>
    public const int VoiceBacklog = ScreenVideoWire.VoiceSampleRate;

    /// <summary>What this viewer asks to see.</summary>
    public sealed record Layout(int Width, int Height, ScreenFit Fit = ScreenFit.Mac, int Fps = 60, ScreenQuality Quality = ScreenQuality.Sharp, int Space = 100);

    private readonly Stream _stream;
    private readonly IAsyncDisposable? _owner;
    private readonly ScreenCodecs _codecs;
    private readonly IScreenSink _sink;
    private readonly Channel<(byte[] Data, bool Voice)> _outgoing = Channel.CreateUnbounded<(byte[], bool)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _stop = new();
    private readonly ScreenVideoWire.Reader _reader = new();
    private readonly Lock _lock = new();
    private ReadOnlyMemory<byte> _initial;
    private Layout _layout;
    private (ScreenCodec Codec, int Width, int Height, IReadOnlyList<byte[]> Sets)? _format;
    private volatile bool _awaitingKeyframe = true;
    private int _copiesAsked;
    private int _voiceUnsent;
    private int _started;
    private volatile bool _disposing;
    private int _closed;
    private Task? _loop;

    /// <param name="owner">Disposed when the stream ends (the shell client's stream); otherwise <paramref name="stream"/> is.</param>
    public ScreenVideoClient(Stream stream, ReadOnlyMemory<byte> initialBytes, Layout layout, ScreenCodecs codecs, IScreenSink sink, IAsyncDisposable? owner = null)
    {
        _stream = stream;
        _initial = initialBytes;
        _layout = layout;
        _codecs = codecs | ScreenCodecs.H264;
        _sink = sink;
        _owner = owner;
    }

    /// <summary>Says hello, takes the bytes that came with the hand-over, then reads until the stream ends.</summary>
    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) == 1) return;
        lock (_lock) Enqueue(ScreenVideoWire.Encode(new ScreenMessage.Hello(HelloOf(_layout))));
        var writer = Task.Run(WriteAllAsync);
        _loop = Task.Run(async () =>
        {
            Exception? error = null;
            try
            {
                var initial = _initial;
                _initial = default;
                Received(initial.Span);
                var buffer = new byte[ReadSize];
                while (true)
                {
                    var read = await _stream.ReadAsync(buffer, _stop.Token).ConfigureAwait(false);
                    if (read == 0) throw new ScreenConnectionLostException();
                    Received(buffer.AsSpan(0, read));
                }
            }
            catch (ScreenWireException e) { error = new MalformedStreamException(e.Message); }
            catch (MalformedStreamException e) { error = e; }
            catch (ScreenConnectionLostException e) { error = e; }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
            {
                error = _disposing ? null : new ScreenConnectionLostException(e);
            }
            catch (Exception e) { error = e; } // a sink's failure ends the view, never the process
            await FinishAsync(error).ConfigureAwait(false);
            await writer.ConfigureAwait(false);
        });
    }

    private ScreenHello HelloOf(Layout l) => new(l.Width, l.Height, l.Fit, _codecs, l.Fps, l.Quality, l.Space);

    /// <summary>Asks for something else to be shown; the Mac answers with <c>fitted</c>, then a new format if the size changed.</summary>
    public void Relayout(Layout layout)
    {
        lock (_lock)
        {
            if (layout == _layout) return;
            _layout = layout;
            Enqueue(ScreenVideoWire.Encode(new ScreenMessage.Hello(HelloOf(layout))));
        }
    }

    /// <summary>Frame <paramref name="number"/> is on screen (or was superseded, or couldn't be shown).</summary>
    public void Shown(uint number) => Send(new ScreenMessage.Ack(number));

    /// <summary>The display couldn't use what it got: frames are skipped until a keyframe arrives.</summary>
    public void RequestKeyframe()
    {
        _awaitingKeyframe = true;
        Send(new ScreenMessage.KeyframeRequest());
    }

    /// <summary>The pointer at (<paramref name="x"/>, <paramref name="y"/>), each 0…1 across the picture, with RFB buttons held (left 1, middle 2, right 4).</summary>
    public void Pointer(double x, double y, byte buttons)
    {
        static ushort Scale(double v) => (ushort)Math.Round(Math.Clamp(double.IsNaN(v) ? 0 : v, 0, 1) * 65535, MidpointRounding.AwayFromZero);
        Send(new ScreenMessage.Pointer(Scale(x), Scale(y), (byte)(buttons & 0b111)));
    }

    /// <summary>Scrolls by stream pixels; positive <paramref name="dy"/> brings earlier content into view.</summary>
    public void Scroll(int dx, int dy)
    {
        if (dx == 0 && dy == 0) return;
        Send(new ScreenMessage.Scroll((short)Math.Clamp(dx, short.MinValue, short.MaxValue), (short)Math.Clamp(dy, short.MinValue, short.MaxValue)));
    }

    public void Key(uint keysym, ScreenModifiers modifiers) => Send(new ScreenMessage.Key(keysym, (byte)modifiers));

    /// <summary>Typed as is, in pieces the Mac accepts.</summary>
    public void Text(string text)
    {
        lock (_lock)
            foreach (var piece in ScreenVideoWire.TextPieces(text)) Enqueue(ScreenVideoWire.Encode(new ScreenMessage.Text(piece)));
    }

    /// <summary>Puts <paramref name="text"/> on the Mac's clipboard; false (nothing sent) when it is over 64 KiB.</summary>
    public bool Clipboard(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > ScreenVideoWire.MaxClipboardPayload) return false;
        Send(new ScreenMessage.Clipboard(text));
        return true;
    }

    /// <summary>Presses ⌘C on the Mac; what it copied comes back through <see cref="IScreenSink.Copied"/>.</summary>
    public void CopySelection()
    {
        if (Volatile.Read(ref _closed) == 1) return;
        Interlocked.Increment(ref _copiesAsked);
        Send(new ScreenMessage.Copy());
    }

    public void Gesture(ScreenGesture gesture, ScreenGesturePhase phase, double value) => Send(new ScreenMessage.Gesture(gesture, phase, value));
    public void Function(bool down) => Send(new ScreenMessage.Function(down));
    public void Sound(bool on) => Send(new ScreenMessage.Sound(on));
    public void Microphone(bool on) => Send(new ScreenMessage.Microphone(on));
    public void UseHere() => Send(new ScreenMessage.UseHere());

    /// <summary>
    /// 16-bit little-endian mono at 16 kHz, in pieces the Mac takes. Voice is for now or never: while half a second of it
    /// is still unsent (a slow link), what comes is left out, so it can't pile up in front of the pointer, keys and acks.
    /// </summary>
    public void Voice(ReadOnlySpan<byte> samples)
    {
        while (!samples.IsEmpty)
        {
            var piece = samples[..Math.Min(samples.Length, ScreenVideoWire.MaxVoicePayload)];
            samples = samples[piece.Length..];
            var data = ScreenVideoWire.Encode(new ScreenMessage.Voice(piece.ToArray()));
            lock (_lock)
            {
                if (_voiceUnsent >= VoiceBacklog) continue;
                _voiceUnsent += data.Length;
                if (!_outgoing.Writer.TryWrite((data, true))) _voiceUnsent -= data.Length;
            }
        }
    }

    private void Send(ScreenMessage message)
    {
        var data = ScreenVideoWire.Encode(message);
        lock (_lock) Enqueue(data);
    }

    private void Enqueue(byte[] data) => _outgoing.Writer.TryWrite((data, false));

    private async Task WriteAllAsync()
    {
        try
        {
            await foreach (var (data, voice) in _outgoing.Reader.ReadAllAsync(_stop.Token).ConfigureAwait(false))
            {
                await _stream.WriteAsync(data, _stop.Token).ConfigureAwait(false);
                if (voice) lock (_lock) _voiceUnsent -= data.Length;
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException or NotSupportedException)
        {
            // The read loop sees the same end and reports it.
            _stop.Cancel();
        }
    }

    // MARK: Reading

    private void Received(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty) return;
        foreach (var message in _reader.Append(data))
        {
            if (Volatile.Read(ref _closed) == 1) return;
            Handle(message);
        }
    }

    private void Handle(ScreenMessage message)
    {
        switch (message)
        {
            case ScreenMessage.Format f:
                CheckFormat(f.Codec, f.Width, f.Height, f.ParameterSets, _codecs);
                if (_format is not { } old || old.Codec != f.Codec || old.Width != f.Width || old.Height != f.Height || !SameSets(old.Sets, f.ParameterSets))
                {
                    _format = (f.Codec, f.Width, f.Height, f.ParameterSets);
                    _sink.Format(f.Codec, f.Width, f.Height, f.ParameterSets);
                }
                break;
            case ScreenMessage.Frame f:
                if (_format is not { } format) { Shown(f.Number); return; }
                if (_awaitingKeyframe)
                {
                    // Without the frames before it, a delta frame can't be shown; still let the Mac send on.
                    if (!f.Keyframe) { Shown(f.Number); return; }
                    _awaitingKeyframe = false;
                }
                if (AnnexB.Convert(f.Data, format.Codec, f.Keyframe, format.Sets) is not { } annexB) { Shown(f.Number); return; }
                _sink.Frame(f.Number, f.Keyframe, annexB);
                break;
            case ScreenMessage.Copied c:
                // The Mac's copies are taken only as answers, so it can't put things on this PC's clipboard unasked.
                if (Interlocked.Decrement(ref _copiesAsked) < 0) { Interlocked.Increment(ref _copiesAsked); return; }
                _sink.Copied(c.Result);
                break;
            case ScreenMessage.MicrophoneState m: _sink.MicrophoneState(m.State); break;
            case ScreenMessage.SoundState s: _sink.SoundState(s.State); break;
            case ScreenMessage.SoundPacket s: _sink.SoundPacket(s.Packet); break;
            case ScreenMessage.Fitted f: _sink.Fitted(f.Fit); break;
            case ScreenMessage.Viewers v: _sink.Viewers(v.Names); break;
            case ScreenMessage.MovedAway m: _sink.MovedAway(m.To); break;
            case ScreenMessage.Cursor c: _sink.Cursor(c.X / 65535.0, c.Y / 65535.0, c.Visible); break;
            case ScreenMessage.CursorShape s:
                // A shape that fails a check is skipped: the pointer keeps the last one. Its real size is read before
                // anything decodes it: a few bytes can claim a huge image.
                if (s.Width > 0 && s.Height > 0 && PngSize(s.Png) is var (w, h) && w is >= 1 and <= MaxCursorSide && h is >= 1 and <= MaxCursorSide)
                    _sink.CursorShape(s.Width, s.Height, s.HotX, s.HotY, s.Png);
                break;
        }
    }

    private static bool SameSets(IReadOnlyList<byte[]> a, IReadOnlyList<byte[]> b) =>
        a.Count == b.Count && a.Zip(b).All(x => x.First.AsSpan().SequenceEqual(x.Second));

    /// <summary>
    /// What a <c>format</c> must be before a decoder sees it: a codec offered; 16…4096 pixels a side; H.264 with exactly an
    /// SPS and a PPS, HEVC with a VPS, SPS and PPS, each 1…4096 bytes; for H.264 an SPS of an allowed profile, 4:2:0, 8 bits,
    /// frames only, whose cropped size is the announced one. Throws <see cref="MalformedStreamException"/>.
    /// </summary>
    public static void CheckFormat(ScreenCodec codec, int width, int height, IReadOnlyList<byte[]> sets, ScreenCodecs offered)
    {
        var bit = codec == ScreenCodec.Hevc ? ScreenCodecs.Hevc : ScreenCodecs.H264;
        if ((offered & bit) == 0) throw new MalformedStreamException("A codec this viewer didn't offer.");
        if (width is < MinStreamSide or > MaxStreamSide || height is < MinStreamSide or > MaxStreamSide)
            throw new MalformedStreamException("A picture size out of range.");
        if (sets.Count != (codec == ScreenCodec.Hevc ? 3 : 2) || sets.Any(s => s.Length is 0 or > MaxParameterSet))
            throw new MalformedStreamException("Wrong parameter sets.");
        if (codec == ScreenCodec.H264)
        {
            if (H264Sps.TryParse(sets[0]) is not { IsAcceptable: true } sps) throw new MalformedStreamException("An SPS this viewer doesn't take.");
            if (sps.Width != width || sps.Height != height) throw new MalformedStreamException("The SPS's size isn't the announced one.");
            if ((sets[1][0] & 0x1F) != 8) throw new MalformedStreamException("The second parameter set isn't a PPS.");
        }
        else
        {
            static int Type(byte[] s) => (s[0] >> 1) & 0x3F;
            if (Type(sets[0]) != 32 || Type(sets[1]) != 33 || Type(sets[2]) != 34) throw new MalformedStreamException("Wrong HEVC parameter sets.");
        }
    }

    /// <summary>A PNG's size from its header (signature, then IHDR first); null when it isn't a PNG.</summary>
    public static (int Width, int Height)? PngSize(ReadOnlySpan<byte> png)
    {
        ReadOnlySpan<byte> signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (png.Length < 33 || !png[..8].SequenceEqual(signature)) return null;
        if (BinaryPrimitives.ReadUInt32BigEndian(png[8..]) != 13 || !png.Slice(12, 4).SequenceEqual("IHDR"u8)) return null;
        var w = BinaryPrimitives.ReadUInt32BigEndian(png[16..]);
        var h = BinaryPrimitives.ReadUInt32BigEndian(png[20..]);
        return w > int.MaxValue || h > int.MaxValue ? null : ((int)w, (int)h);
    }

    // MARK: Ending

    private async Task FinishAsync(Exception? error)
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _stop.Cancel();
        _outgoing.Writer.TryComplete();
        try
        {
            if (_owner is not null) await _owner.DisposeAsync().ConfigureAwait(false);
            else await _stream.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }
        try { _sink.Closed(error); }
        catch (Exception) { } // a sink's failure on the way out changes nothing
    }

    /// <summary>Ends the stream; <see cref="IScreenSink.Closed"/> is told with no error.</summary>
    public async ValueTask DisposeAsync()
    {
        _disposing = true;
        _stop.Cancel();
        if (_loop is { } loop) await loop.ConfigureAwait(false);
        else await FinishAsync(null).ConfigureAwait(false);
    }
}
