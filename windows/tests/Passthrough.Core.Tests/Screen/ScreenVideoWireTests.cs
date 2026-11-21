using System.Text;
using Passthrough.Core.Screen;
using Xunit;
using M = Passthrough.Core.Screen.ScreenMessage;

namespace Passthrough.Core.Tests.Screen;

/// <summary>The Swift ScreenVideoWireTests' cases (ScreenHostTests.swift), against the C# port.</summary>
public sealed class ScreenVideoWireTests
{
    internal static IEnumerable<ScreenMessage> Everything() =>
    [
        new M.Format(ScreenCodec.H264, 1728, 1116, [[0x67, 1, 2], [0x68, 3]]),
        new M.Format(ScreenCodec.Hevc, 1206, 2622, [[0x40, 1], [0x42, 2], [0x44, 3]]),
        new M.Frame(7, true, Enumerable.Repeat((byte)5, 300).ToArray()),
        new M.Frame(8, false, []),
        new M.Hello(new ScreenHello(2868, 1320)),
        new M.Hello(new ScreenHello(1206, 2622, ScreenFit.Device, ScreenCodecs.H264 | ScreenCodecs.Hevc)),
        new M.Hello(new ScreenHello(2752, 2064, ScreenFit.Device, ScreenCodecs.H264, 120, ScreenQuality.Fast, 125)),
        new M.Viewers([]),
        new M.Viewers(["iPad Pro", "Someone’s iPhone 👋"]),
        new M.MovedAway("iPad Pro"),
        new M.UseHere(),
        new M.Gesture(ScreenGesture.Magnify, ScreenGesturePhase.Began, 0),
        new M.Gesture(ScreenGesture.Magnify, ScreenGesturePhase.Changed, 0.0125),
        new M.Gesture(ScreenGesture.Rotate, ScreenGesturePhase.Changed, -12.5),
        new M.Gesture(ScreenGesture.Rotate, ScreenGesturePhase.Ended, 0),
        new M.Fitted(ScreenFit.Device),
        new M.Fitted(ScreenFit.Mac),
        new M.Cursor(1, 65535, true),
        new M.Cursor(0, 0, false),
        new M.CursorShape(17, 23, 4, 0, [0x89, 0x50, 0x4E, 0x47]),
        new M.Ack(0xFFFF_FFFE),
        new M.Pointer(65535, 0, 5),
        new M.Scroll(-3, 1200),
        new M.Key(0xFF51, (byte)ScreenModifiers.Control),
        new M.Text("héllo 👋"),
        new M.Microphone(true),
        new M.Microphone(false),
        new M.Voice([1, 2, 3, 4]),
        new M.Voice([]),
        new M.MicrophoneState(ScreenMicrophoneState.On),
        new M.MicrophoneState(ScreenMicrophoneState.NotInstalled),
        new M.Function(true),
        new M.Function(false),
        new M.Sound(true),
        new M.SoundState(ScreenSoundState.On),
        new M.SoundState(ScreenSoundState.Failed),
        new M.SoundPacket([0x21, 0x10, 0x05]),
        new M.Clipboard(""),
        new M.KeyframeRequest(),
        new M.Copy(),
        new M.Copied(new ScreenCopyResult.Text("copié ✂︎")),
        new M.Copied(new ScreenCopyResult.Text("")),
        new M.Copied(new ScreenCopyResult.Nothing()),
        new M.Copied(new ScreenCopyResult.TooLong()),
        new M.Copied(new ScreenCopyResult.NotText()),
        new M.Curtain(true),
        new M.Curtain(false),
        new M.Curtained(true),
        new M.Curtained(false),
    ];

    private static byte[] Header(byte type, int length) => [type, (byte)(length >> 24), (byte)(length >> 16), (byte)(length >> 8), (byte)length];

    [Fact]
    public void RoundTripInPieces()
    {
        var messages = Everything().ToList();
        var bytes = messages.SelectMany(ScreenVideoWire.Encode).ToArray();
        var reader = new ScreenVideoWire.Reader();
        var decoded = new List<ScreenMessage>();
        // A byte at a time: nothing is assumed about how the stream splits.
        foreach (var b in bytes) decoded.AddRange(reader.Append([b]));
        Assert.Equal(messages.Count, decoded.Count);
        for (var i = 0; i < messages.Count; i++)
        {
            Assert.Equal(messages[i].GetType(), decoded[i].GetType());
            Assert.Equal(ScreenVideoWire.Encode(messages[i]), ScreenVideoWire.Encode(decoded[i]));
        }
        Assert.Equal(-12.5, ((M.Gesture)decoded[13]).Value);
        Assert.Equal("Someone’s iPhone 👋", ((M.Viewers)decoded[8]).Names[1]);
        Assert.Equal(new ScreenHello(2752, 2064, ScreenFit.Device, ScreenCodecs.H264, 120, ScreenQuality.Fast, 125), ((M.Hello)decoded[6]).Value);
        Assert.Equal(new ScreenCopyResult.Text("copié ✂︎"), ((M.Copied)decoded[40]).Result);
    }

    [Fact]
    public void TheWireIsAsTheMacWritesIt()
    {
        Assert.Equal([17, 0, 0, 0, 4, 0xFF, 0xFF, 0xFF, 0xFE], ScreenVideoWire.Encode(new M.Ack(0xFFFF_FFFE)));
        Assert.Equal([16, 0, 0, 0, 9, 0x0B, 0x34, 0x05, 0x28, 0, 3, 60, 0, 100],
            ScreenVideoWire.Encode(new M.Hello(new ScreenHello(2868, 1320, Codecs: ScreenCodecs.H264 | ScreenCodecs.Hevc))));
        Assert.Equal([19, 0, 0, 0, 4, 0xFF, 0xFD, 0x04, 0xB0], ScreenVideoWire.Encode(new M.Scroll(-3, 1200)));
        Assert.Equal([27, 0, 0, 0, 6, 1, 2, 0xFF, 0xFE, 0x17, 0xB8], ScreenVideoWire.Encode(new M.Gesture(ScreenGesture.Rotate, ScreenGesturePhase.Changed, -12.5)));
    }

    [Fact]
    public void SkipsUnknownTypesAndRefusesHugeOnes()
    {
        var reader = new ScreenVideoWire.Reader();
        var got = reader.Append([200, 0, 0, 0, 2, 9, 9, .. ScreenVideoWire.Encode(new M.KeyframeRequest())]);
        Assert.IsType<M.KeyframeRequest>(Assert.Single(got));
        Assert.True(Assert.Throws<ScreenWireException>(() => new ScreenVideoWire.Reader().Append([2, 0x7F, 0, 0, 0])).TooLarge);
        Assert.False(Assert.Throws<ScreenWireException>(() => new ScreenVideoWire.Reader().Append([17, 0, 0, 0, 1, 0])).TooLarge); // an ack needs 4 bytes
    }

    /// <summary>What the Mac reads from a viewer has a cap per type, checked from the header before the payload is buffered.</summary>
    [Theory]
    [InlineData(21, ScreenVideoWire.MaxTextPayload)]
    [InlineData(22, ScreenVideoWire.MaxClipboardPayload)]
    [InlineData(29, ScreenVideoWire.MaxVoicePayload)]
    [InlineData(18, 64)]
    [InlineData(17, 64)]
    [InlineData(2, 64)]
    [InlineData(200, ScreenVideoWire.MaxClipboardPayload)]
    public void PhoneMessagesHaveSmallCaps(byte type, int cap)
    {
        Assert.Throws<ScreenWireException>(() => new ScreenVideoWire.Reader(ScreenSender.Phone).Append(Header(type, cap + 1)));
        Assert.Empty(new ScreenVideoWire.Reader(ScreenSender.Phone).Append(Header(type, cap))); // at its cap: waits for the payload
    }

    [Fact]
    public void TheMacsMessagesKeepTheLargeCapButCopiesAreHeldToAPaste()
    {
        Assert.Empty(new ScreenVideoWire.Reader().Append(Header(2, 8 << 20)));
        Assert.Empty(new ScreenVideoWire.Reader().Append(Header(2, ScreenVideoWire.MaxPayload)));
        Assert.Throws<ScreenWireException>(() => new ScreenVideoWire.Reader().Append(Header(2, ScreenVideoWire.MaxPayload + 1)));
        Assert.Throws<ScreenWireException>(() => new ScreenVideoWire.Reader().Append(Header(3, ScreenVideoWire.MaxClipboardPayload + 2)));
        Assert.Empty(new ScreenVideoWire.Reader().Append(Header(3, ScreenVideoWire.MaxClipboardPayload + 1)));
        var text = new string('é', 2048);
        var exact = new ScreenVideoWire.Reader(ScreenSender.Phone).Append(ScreenVideoWire.Encode(new M.Text(text)));
        Assert.Equal(text, Assert.IsType<M.Text>(Assert.Single(exact)).Value); // 4 KiB of text is one message
    }

    [Fact]
    public void DecodingIsTolerantWhereTheMacSaysSo()
    {
        static ScreenMessage One(params byte[] bytes) => Assert.Single(new ScreenVideoWire.Reader().Append(bytes));
        // A fit or quality added later reads as the first; H.264 is always decodable; fps and space are clamped.
        var hello = Assert.IsType<M.Hello>(One(16, 0, 0, 0, 9, 0, 10, 0, 10, 9, 2, 1, 9, 255)).Value;
        Assert.Equal(new ScreenHello(10, 10, ScreenFit.Mac, ScreenCodecs.H264 | ScreenCodecs.Hevc, 15, ScreenQuality.Sharp, 200), hello);
        Assert.IsType<ScreenCopyResult.Nothing>(Assert.IsType<M.Copied>(One(3, 0, 0, 0, 1, 9)).Result);
        Assert.Equal(ScreenSoundState.Failed, Assert.IsType<M.SoundState>(One(11, 0, 0, 0, 1, 7)).State);
        Assert.Equal(ScreenMicrophoneState.Failed, Assert.IsType<M.MicrophoneState>(One(10, 0, 0, 0, 1, 7)).State);
        Assert.Equal([1, 2], Assert.IsType<M.Voice>(One(29, 0, 0, 0, 3, 1, 2, 3)).Samples); // whole samples only
        Assert.Equal(ScreenFit.Mac, Assert.IsType<M.Fitted>(One(5, 0, 0, 0, 1, 9)).Fit);
        Assert.Throws<ScreenWireException>(() => One(1, 0, 0, 0, 6, 9, 0, 16, 0, 16, 0)); // an unknown codec
        Assert.Throws<ScreenWireException>(() => One(1, 0, 0, 0, 8, 0, 0, 16, 0, 16, 1, 0, 9)); // a set past the end
        Assert.Throws<ScreenWireException>(() => One(27, 0, 0, 0, 6, 0, 3, 0, 0, 0, 0)); // an unknown phase
    }

    /// <summary>Long text is sent in pieces under the cap, split between characters.</summary>
    [Fact]
    public void TextPieces()
    {
        Assert.Empty(ScreenVideoWire.TextPieces(""));
        Assert.Equal(["hi"], ScreenVideoWire.TextPieces("hi"));
        var longText = string.Concat(Enumerable.Repeat("ab👋", 3000)); // 6 bytes each: 18 000 bytes
        var pieces = ScreenVideoWire.TextPieces(longText);
        Assert.Equal(longText, string.Concat(pieces));
        Assert.All(pieces, p => Assert.True(Encoding.UTF8.GetByteCount(p) <= ScreenVideoWire.MaxTextPayload));
        Assert.Equal(5, pieces.Count);
        const string family = "👨‍👩‍👧‍👦"; // one character of 25 bytes
        Assert.Equal(family + "x", string.Concat(ScreenVideoWire.TextPieces(family + "x", maxBytes: 10)));
        Assert.All(ScreenVideoWire.TextPieces(family, maxBytes: 10), p => Assert.True(Encoding.UTF8.GetByteCount(p) <= 10));
    }

    [Fact]
    public void NamesAreCutToWhatTheWireCarries()
    {
        var name = string.Concat(Enumerable.Repeat("👋", 70));
        var decoded = (M.Viewers)Assert.Single(new ScreenVideoWire.Reader().Append(ScreenVideoWire.Encode(new M.Viewers(Enumerable.Repeat(name, 20).ToList()))));
        Assert.Equal(16, decoded.Names.Count);
        Assert.Equal(string.Concat(Enumerable.Repeat("👋", 63)), decoded.Names[0].TrimEnd('�')); // 255 bytes: 63 whole, one cut
        var moved = (M.MovedAway)Assert.Single(new ScreenVideoWire.Reader().Append(ScreenVideoWire.Encode(new M.MovedAway(name))));
        Assert.Equal(string.Concat(Enumerable.Repeat("👋", 64)), moved.To);
    }

    /// <summary>Random bytes never get anything out of the reader but messages or <see cref="ScreenWireException"/>.</summary>
    [Fact]
    public void RandomBytesNeverThrowAnythingElse()
    {
        var random = new Random(8);
        for (var round = 0; round < 3000; round++)
        {
            var length = random.Next(0, 80);
            var bytes = new byte[length];
            random.NextBytes(bytes);
            // Mostly known types with short lengths, so payloads are actually decoded.
            if (length >= 5) { bytes[0] = (byte)random.Next(0, 33); bytes[1] = bytes[2] = bytes[3] = 0; bytes[4] = (byte)random.Next(0, length - 4); }
            try { new ScreenVideoWire.Reader().Append(bytes); }
            catch (ScreenWireException) { }
        }
    }
}
