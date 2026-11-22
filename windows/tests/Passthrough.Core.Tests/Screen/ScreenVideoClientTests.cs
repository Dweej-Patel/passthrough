using System.Buffers;
using System.Threading.Channels;
using Passthrough.Core.Screen;
using Passthrough.Core.Tests.Pipe;
using Xunit;
using M = Passthrough.Core.Screen.ScreenMessage;

namespace Passthrough.Core.Tests.Screen;

/// <summary>What a Mac sends the screen client is checked before it is used (ScreenClientTests.swift, and the client cases of ScreenHostTests.swift).</summary>
public sealed class ScreenVideoClientTests : IAsyncDisposable
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);
    private readonly Stream _mac, _viewer;
    private readonly Sink _sink = new();
    private readonly ScreenVideoWire.Reader _heard = new(ScreenSender.Phone);
    private ScreenVideoClient? _client;

    public ScreenVideoClientTests() => (_mac, _viewer) = DuplexStreams.Create();

    public async ValueTask DisposeAsync()
    {
        if (_client is not null) await _client.DisposeAsync();
        _mac.Dispose();
    }

    internal sealed class Sink : IScreenSink
    {
        public readonly Channel<object> Events = Channel.CreateUnbounded<object>();
        public void Format(ScreenCodec codec, int width, int height, IReadOnlyList<byte[]> parameterSets) => Events.Writer.TryWrite(("format", codec, width, height));
        public void Frame(uint number, bool keyframe, IMemoryOwner<byte> annexB)
        {
            Events.Writer.TryWrite(("frame", number, keyframe, annexB.Memory.ToArray()));
            annexB.Dispose();
        }
        public void Fitted(ScreenFit fit) => Events.Writer.TryWrite(fit);
        public void Cursor(double x, double y, bool visible) => Events.Writer.TryWrite(("cursor", x, y, visible));
        public void CursorShape(int width, int height, int hotX, int hotY, ReadOnlyMemory<byte> png) => Events.Writer.TryWrite(("shape", width, height));
        public void Viewers(IReadOnlyList<string> names) => Events.Writer.TryWrite(("viewers", string.Join(",", names)));
        public void MovedAway(string to) => Events.Writer.TryWrite(("moved", to));
        public void Copied(ScreenCopyResult result) => Events.Writer.TryWrite(result);
        public void SoundState(ScreenSoundState state) => Events.Writer.TryWrite(state);
        public void SoundPacket(ReadOnlyMemory<byte> packet) => Events.Writer.TryWrite(("sound", packet.Length));
        public void MicrophoneState(ScreenMicrophoneState state) => Events.Writer.TryWrite(state);
        public void Closed(Exception? error)
        {
            Events.Writer.TryWrite(("closed", error?.GetType().Name ?? "none"));
            Events.Writer.TryComplete();
        }

        public async Task<object> Next() => await Events.Reader.ReadAsync().AsTask().WaitAsync(Wait);
    }

    private ScreenVideoClient Start(ReadOnlyMemory<byte> initial = default, ScreenCodecs codecs = ScreenCodecs.H264)
    {
        _client = new ScreenVideoClient(_viewer, initial, new ScreenVideoClient.Layout(2560, 2560), codecs, _sink);
        _client.Start();
        return _client;
    }

    private Task Send(params ScreenMessage[] messages) => _mac.WriteAsync(messages.SelectMany(ScreenVideoWire.Encode).ToArray()).AsTask();

    /// <summary>The next message the client sent the Mac.</summary>
    private async Task<ScreenMessage> Heard()
    {
        var buffer = new byte[1];
        while (true)
        {
            if (_pending.Count > 0) return _pending.Dequeue();
            var n = await _mac.ReadAsync(buffer).AsTask().WaitAsync(Wait);
            if (n == 0) throw new IOException("closed");
            foreach (var m in _heard.Append(buffer.AsSpan(0, n))) _pending.Enqueue(m);
        }
    }

    private readonly Queue<ScreenMessage> _pending = new();

    internal static IReadOnlyList<byte[]> H264Sets(int width, int height) => [SpsBuilder.Sps(width, height), [0x68, 0xCE, 0x3C, 0x80]];

    private static M.Format Format(int width = 1280, int height = 720) => new(ScreenCodec.H264, width, height, H264Sets(width, height));

    private static byte[] Avcc(params byte[] unit) => [0, 0, 0, (byte)unit.Length, .. unit];

    [Fact]
    public async Task SaysHelloFirstThenReadsTheBytesThatCameWithTheHandOver()
    {
        Start(ScreenVideoWire.Encode(new M.Fitted(ScreenFit.Device)));
        var hello = Assert.IsType<M.Hello>(await Heard()).Value;
        Assert.Equal(new ScreenHello(2560, 2560, ScreenFit.Mac, ScreenCodecs.H264, 60, ScreenQuality.Sharp, 100), hello);
        Assert.Equal(ScreenFit.Device, await _sink.Next());
    }

    [Fact]
    public async Task RelayoutSaysHelloAgainOnlyWhenItChanged()
    {
        var client = Start(codecs: ScreenCodecs.H264 | ScreenCodecs.Hevc);
        Assert.Equal(ScreenCodecs.H264 | ScreenCodecs.Hevc, Assert.IsType<M.Hello>(await Heard()).Value.Codecs);
        client.Relayout(new ScreenVideoClient.Layout(2560, 2560));
        client.Relayout(new ScreenVideoClient.Layout(2560, 2560, Fps: 15));
        Assert.Equal(15, Assert.IsType<M.Hello>(await Heard()).Value.Fps);
    }

    [Fact]
    public async Task FramesBeforeAFormatOrTheAwaitedKeyframeAreAckedNotShown()
    {
        var client = Start();
        await Heard();
        await Send(new M.Frame(1, true, Avcc(0x65, 1)));        // no format yet
        Assert.Equal(1u, Assert.IsType<M.Ack>(await Heard()).Number);
        await Send(Format(), new M.Frame(2, false, Avcc(0x41, 1))); // a delta while awaiting the keyframe
        Assert.Equal(("format", ScreenCodec.H264, 1280, 720), await _sink.Next());
        Assert.Equal(2u, Assert.IsType<M.Ack>(await Heard()).Number);
        await Send(new M.Frame(3, true, Avcc(0x65, 1)), new M.Frame(4, false, Avcc(0x41, 2)));
        var key = ((string, uint, bool, byte[]))await _sink.Next();
        Assert.Equal((3u, true), (key.Item2, key.Item3));
        Assert.Equal([0, 0, 0, 1, .. H264Sets(1280, 720)[0], 0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80, 0, 0, 0, 1, 0x65, 1], key.Item4);
        Assert.Equal(4u, (((string, uint, bool, byte[]))await _sink.Next()).Item2);
        // After a keyframe request, deltas are skipped again until one comes.
        client.RequestKeyframe();
        Assert.IsType<M.KeyframeRequest>(await Heard());
        await Send(new M.Frame(5, false, Avcc(0x41, 3)), new M.Frame(6, true, Avcc(0x65, 4)));
        Assert.Equal(5u, Assert.IsType<M.Ack>(await Heard()).Number);
        Assert.Equal(6u, (((string, uint, bool, byte[]))await _sink.Next()).Item2);
        client.Shown(6);
        Assert.Equal(6u, Assert.IsType<M.Ack>(await Heard()).Number);
    }

    [Fact]
    public async Task TheSameFormatAgainIsNotHandedOnAndANewSizeIs()
    {
        Start();
        await Send(Format(), Format(), Format(1920, 1080));
        Assert.Equal(("format", ScreenCodec.H264, 1280, 720), await _sink.Next());
        Assert.Equal(("format", ScreenCodec.H264, 1920, 1080), await _sink.Next());
    }

    /// <summary>The viewer takes the Mac's copies only as answers: one sent unasked is dropped.</summary>
    [Fact]
    public async Task CopiesAreTakenOnlyAsAnswers()
    {
        var client = Start();
        await Heard();
        await Send(new M.Copied(new ScreenCopyResult.Text("pushed")), new M.Fitted(ScreenFit.Mac));
        Assert.Equal(ScreenFit.Mac, await _sink.Next());
        client.CopySelection();
        Assert.IsType<M.Copy>(await Heard());
        await Send(new M.Copied(new ScreenCopyResult.Text("answer")), new M.Copied(new ScreenCopyResult.Text("pushed again")), new M.Fitted(ScreenFit.Device));
        Assert.Equal(new ScreenCopyResult.Text("answer"), await _sink.Next());
        Assert.Equal(ScreenFit.Device, await _sink.Next());
    }

    [Fact]
    public async Task InputGoesOutInOrderAndLongTextInPieces()
    {
        var client = Start();
        await Heard();
        client.Pointer(0.5, 2, 1 | 8);
        client.Scroll(0, 0); // nothing
        client.Scroll(-100_000, 3);
        client.Key(0xFF0D, ScreenModifiers.Command | ScreenModifiers.Shift);
        client.Text(new string('x', ScreenVideoWire.MaxTextPayload + 1));
        client.Function(true);
        Assert.Equal(new M.Pointer(32768, 65535, 1), await Heard());
        Assert.Equal(new M.Scroll(short.MinValue, 3), await Heard());
        Assert.Equal(new M.Key(0xFF0D, 3), await Heard());
        Assert.Equal(ScreenVideoWire.MaxTextPayload, Assert.IsType<M.Text>(await Heard()).Value.Length);
        Assert.Equal("x", Assert.IsType<M.Text>(await Heard()).Value);
        Assert.Equal(new M.Function(true), await Heard());
    }

    [Fact]
    public async Task AClipboardOverTheLimitIsNotSent()
    {
        var client = Start();
        await Heard();
        Assert.False(client.Clipboard(new string('x', ScreenVideoWire.MaxClipboardPayload + 1)));
        Assert.True(client.Clipboard("héllo"));
        Assert.Equal("héllo", Assert.IsType<M.Clipboard>(await Heard()).Value);
    }

    [Fact]
    public async Task VoiceGoesInPiecesTheMacTakes()
    {
        var client = Start();
        await Heard();
        client.Voice(new byte[ScreenVideoWire.MaxVoicePayload + 2]);
        Assert.Equal(ScreenVideoWire.MaxVoicePayload, Assert.IsType<M.Voice>(await Heard()).Samples.Length);
        Assert.Equal(2, Assert.IsType<M.Voice>(await Heard()).Samples.Length);
    }

    /// <summary>With half a second of voice unsent (a writer that doesn't drain), more voice is left out but other messages still queue.</summary>
    [Fact]
    public async Task VoiceIsDroppedWhileHalfASecondIsUnsent()
    {
        var stalled = new StalledStream();
        await using var client = new ScreenVideoClient(stalled, default, new ScreenVideoClient.Layout(100, 100), ScreenCodecs.H264, _sink);
        client.Start();
        for (var i = 0; i < 100; i++) client.Voice(new byte[320]);
        client.Key(1, ScreenModifiers.None);
        stalled.Release.TrySetResult();
        await stalled.Seen(m => m is M.Key);
        var voices = stalled.Messages.Count(m => m is M.Voice);
        Assert.InRange(voices, 1, ScreenVideoClient.VoiceBacklog / 325 + 1);
    }

    private sealed class StalledStream : Stream
    {
        public readonly TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly ScreenVideoWire.Reader _reader = new(ScreenSender.Phone);
        public readonly List<ScreenMessage> Messages = [];
        private readonly TaskCompletionSource _never = new();

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancel = default)
        {
            await Release.Task.WaitAsync(cancel);
            lock (Messages) Messages.AddRange(_reader.Append(buffer.Span));
        }

        public async Task Seen(Func<ScreenMessage, bool> what)
        {
            for (var i = 0; i < 500; i++)
            {
                lock (Messages) if (Messages.Any(what)) return;
                await Task.Delay(10);
            }
            throw new TimeoutException();
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default)
        {
            await _never.Task.WaitAsync(cancel);
            return 0;
        }

        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    /// <summary>A pointer image is checked for its real size before anything decodes it: a few bytes claiming a huge image are skipped.</summary>
    [Fact]
    public async Task AHugePointerImageIsSkipped()
    {
        Start();
        await Send(new M.CursorShape(10, 10, 0, 0, Png(2048, 2048)), new M.CursorShape(20, 20, 0, 0, [1, 2, 3]),
            new M.CursorShape(0, 20, 0, 0, Png(64, 64)), new M.CursorShape(20, 20, 1, 1, Png(64, 64)));
        Assert.Equal(("shape", 20, 20), await _sink.Next());
        Assert.Equal((64, 64), ScreenVideoClient.PngSize(Png(64, 64)));
        Assert.Null(ScreenVideoClient.PngSize(Png(64, 64)[..20]));
    }

    /// <summary>A PNG's signature and IHDR (enough for the size check; nothing here decodes it).</summary>
    internal static byte[] Png(int width, int height) =>
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R',
         (byte)(width >> 24), (byte)(width >> 16), (byte)(width >> 8), (byte)width,
         (byte)(height >> 24), (byte)(height >> 16), (byte)(height >> 8), (byte)height, 8, 6, 0, 0, 0, 0, 0, 0, 0];

    [Fact]
    public async Task TheRestIsHandedOn()
    {
        Start();
        await Send(new M.Cursor(0, 65535, true), new M.Viewers(["iPad", "iPhone"]), new M.SoundState(ScreenSoundState.On), new M.SoundPacket([1, 2, 3]),
            new M.MicrophoneState(ScreenMicrophoneState.NotInstalled), new M.Curtained(true), new M.MovedAway("iPad"));
        Assert.Equal(("cursor", 0.0, 1.0, true), await _sink.Next());
        Assert.Equal(("viewers", "iPad,iPhone"), await _sink.Next());
        Assert.Equal(ScreenSoundState.On, await _sink.Next());
        Assert.Equal(("sound", 3), await _sink.Next());
        Assert.Equal(ScreenMicrophoneState.NotInstalled, await _sink.Next());
        Assert.Equal(("moved", "iPad"), await _sink.Next());
    }

    /// <summary>Each way a format or frame can be wrong closes the stream as malformed, once, without throwing out of the reader.</summary>
    public static TheoryData<string, byte[]> Malformed() => new()
    {
        { "no parameter sets", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 10, 10, [[], []])) },
        { "an empty SPS", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [[], [0x68, 0xCE, 0x3C, 0x80]])) },
        { "an empty PPS", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [SpsBuilder.Sps(1280, 720), []])) },
        { "one set", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [SpsBuilder.Sps(1280, 720)])) },
        { "HEVC not offered", ScreenVideoWire.Encode(new M.Format(ScreenCodec.Hevc, 1280, 720, [[0x40, 1], [0x42, 1], [0x44, 1]])) },
        { "too small", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 8, 8, H264Sets(8, 8))) },
        { "too big", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 4112, 720, H264Sets(4112, 720))) },
        { "the SPS says another size", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, H264Sets(1920, 1080))) },
        { "a 10-bit SPS", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [SpsBuilder.Sps(1280, 720, bitDepth: 10), [0x68, 1]])) },
        { "a PPS that isn't", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [SpsBuilder.Sps(1280, 720), [0x65, 1]])) },
        { "a set over 4 KiB", ScreenVideoWire.Encode(new M.Format(ScreenCodec.H264, 1280, 720, [SpsBuilder.Sps(1280, 720), [0x68, .. new byte[4096]]])) },
        { "an empty keyframe", [.. ScreenVideoWire.Encode(Format()), .. ScreenVideoWire.Encode(new M.Frame(1, true, []))] },
        { "a NAL past the end", [.. ScreenVideoWire.Encode(Format()), .. ScreenVideoWire.Encode(new M.Frame(1, true, [0, 0, 0, 9, 0x65]))] },
        { "a zero NAL length", [.. ScreenVideoWire.Encode(Format()), .. ScreenVideoWire.Encode(new M.Frame(1, true, [0, 0, 0, 0]))] },
        { "a frame over 16 MiB", [2, 0x01, 0, 0, 1] },
        { "a short ack-sized frame", [2, 0, 0, 0, 3, 0, 0, 1] },
    };

    [Theory]
    [MemberData(nameof(Malformed))]
    public async Task AMalformedStreamClosesAsMalformed(string what, byte[] bytes)
    {
        Start();
        await _mac.WriteAsync(bytes);
        var e = await _sink.Next();
        if (e is ValueTuple<string, ScreenCodec, int, int>) e = await _sink.Next(); // the good format before a bad frame
        Assert.Equal(("closed", nameof(MalformedStreamException)), e);
        Assert.False(await _sink.Events.Reader.WaitToReadAsync().AsTask().WaitAsync(Wait), what); // closed once, nothing after
    }

    /// <summary>Random formats, frames and pointer shapes, after a good format: the client hands on or closes, never throws, closes at most once.</summary>
    [Fact]
    public async Task FuzzedFormatsFramesAndPointersNeverThrowOutOfTheReader()
    {
        var random = new Random(16);
        for (var round = 0; round < 150; round++)
        {
            var (mac, viewer) = DuplexStreams.Create();
            var sink = new Sink();
            await using var client = new ScreenVideoClient(viewer, default, new ScreenVideoClient.Layout(100, 100), ScreenCodecs.H264 | ScreenCodecs.Hevc, sink);
            client.Start();
            var bytes = new List<byte>(ScreenVideoWire.Encode(Format()));
            for (var i = 0; i < 6; i++)
            {
                var message = ScreenVideoWire.Encode(random.Next(4) switch
                {
                    0 => new M.Format((ScreenCodec)random.Next(2), random.Next(0, 5000), random.Next(0, 5000),
                        [.. Enumerable.Range(0, random.Next(0, 4)).Select(_ => Bytes(random, random.Next(0, 30)))]),
                    1 => new M.Format(ScreenCodec.H264, 1280, 720, [Mutate(random, SpsBuilder.Sps(1280, 720)), [0x68, 1]]),
                    2 => new M.Frame((uint)i, random.Next(2) == 0, Bytes(random, random.Next(0, 40))),
                    _ => new M.CursorShape(random.Next(0, 3000), random.Next(0, 3000), 0, 0, Mutate(random, Png(random.Next(0, 3000), random.Next(0, 3000)))),
                });
                if (random.Next(5) == 0) message = Mutate(random, message);
                bytes.AddRange(message);
            }
            await mac.WriteAsync(bytes.ToArray());
            mac.Dispose();
            var closes = 0;
            await foreach (var e in sink.Events.Reader.ReadAllAsync().WithCancellation(new CancellationTokenSource(Wait).Token))
                if (e is ValueTuple<string, string> { Item1: "closed" } closed)
                {
                    closes++;
                    Assert.True(closed.Item2 is nameof(MalformedStreamException) or nameof(ScreenConnectionLostException), closed.Item2);
                }
            Assert.Equal(1, closes);
        }
    }

    private static byte[] Bytes(Random random, int count)
    {
        var b = new byte[count];
        random.NextBytes(b);
        return b;
    }

    private static byte[] Mutate(Random random, byte[] bytes)
    {
        var copy = bytes.ToArray();
        for (var i = 0; i < 1 + random.Next(3) && copy.Length > 0; i++) copy[random.Next(copy.Length)] = (byte)random.Next(256);
        return copy;
    }

    [Fact]
    public async Task TheMacClosingIsALostConnectionAndDisposingIsQuiet()
    {
        Start();
        _mac.Dispose();
        Assert.Equal(("closed", nameof(ScreenConnectionLostException)), await _sink.Next());

        var (mac, viewer) = DuplexStreams.Create();
        var sink = new Sink();
        var client = new ScreenVideoClient(viewer, default, new ScreenVideoClient.Layout(100, 100), ScreenCodecs.H264, sink);
        client.Start();
        await client.DisposeAsync();
        Assert.Equal(("closed", "none"), await sink.Next());
        await client.DisposeAsync();
        mac.Dispose();
    }
}
