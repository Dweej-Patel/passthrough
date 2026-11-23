using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace Passthrough.Core.Screen;

/// <summary>Which display the stream shows: the Mac's own, or one it makes in the viewer's shape.</summary>
public enum ScreenFit : byte { Mac = 0, Device = 1 }

public enum ScreenCodec : byte { H264 = 0, Hevc = 1 }

/// <summary>The codecs a viewer decodes (HEVC only with hardware decode).</summary>
[Flags]
public enum ScreenCodecs : byte { None = 0, H264 = 1, Hevc = 2 }

/// <summary>What matters most when the link can't carry it all.</summary>
public enum ScreenQuality : byte { Sharp = 0, Smooth = 1, Fast = 2 }

/// <summary>The Mac's modifier bits, as <c>key</c> carries them.</summary>
[Flags]
public enum ScreenModifiers : byte { None = 0, Command = 1, Shift = 2, Option = 4, Control = 8 }

public enum ScreenSoundState : byte { Off = 0, On = 1, Failed = 3 }

public enum ScreenMicrophoneState : byte { Off = 0, On = 1, NotInstalled = 2, Failed = 3 }

public enum ScreenGesture : byte { Magnify = 0, Rotate = 1 }

/// <summary>As macOS numbers a gesture's phases.</summary>
public enum ScreenGesturePhase : byte { Began = 1, Changed = 2, Ended = 4, Cancelled = 8 }

/// <summary>Who wrote the bytes a <see cref="ScreenVideoWire.Reader"/> splits, which sets how large each payload may be.</summary>
public enum ScreenSender { Mac, Phone }

/// <summary>What a viewer asks to see: first, and again whenever that changes.</summary>
public sealed record ScreenHello(int Width, int Height, ScreenFit Fit = ScreenFit.Mac, ScreenCodecs Codecs = ScreenCodecs.H264, int Fps = 60,
    ScreenQuality Quality = ScreenQuality.Sharp, int Space = 100);

/// <summary>What a <c>copy</c> found: only what that ⌘C put on the Mac's clipboard.</summary>
public abstract record ScreenCopyResult
{
    public sealed record Text(string Value) : ScreenCopyResult;
    /// <summary>The clipboard didn't change: nothing was selected, or the app doesn't copy.</summary>
    public sealed record Nothing : ScreenCopyResult;
    /// <summary>Text longer than <see cref="ScreenVideoWire.MaxClipboardPayload"/>.</summary>
    public sealed record TooLong : ScreenCopyResult;
    /// <summary>Something that isn't text (an image, a file).</summary>
    public sealed record NotText : ScreenCopyResult;
}

/// <summary>One message of the Mac's screen stream (protocol/README.md, "Screen video"), either way.</summary>
public abstract record ScreenMessage
{
    // Mac → viewer
    /// <summary>The codec, size in pixels and parameter sets (H.264: SPS, PPS; HEVC: VPS, SPS, PPS); before every keyframe.</summary>
    public sealed record Format(ScreenCodec Codec, int Width, int Height, IReadOnlyList<byte[]> ParameterSets) : ScreenMessage;
    /// <summary>One frame: NAL units after 4-byte lengths, numbered from 1.</summary>
    public sealed record Frame(uint Number, bool Keyframe, byte[] Data) : ScreenMessage;
    public sealed record Copied(ScreenCopyResult Result) : ScreenMessage;
    public sealed record Curtained(bool Hidden) : ScreenMessage;
    public sealed record Fitted(ScreenFit Fit) : ScreenMessage;
    /// <summary>The Mac's pointer, each 0…65535 across the stream, or not on the streamed display.</summary>
    public sealed record Cursor(ushort X, ushort Y, bool Visible) : ScreenMessage;
    /// <summary>A PNG drawn <c>Width</c>×<c>Height</c> stream pixels, its tip at (<c>HotX</c>, <c>HotY</c>).</summary>
    public sealed record CursorShape(int Width, int Height, int HotX, int HotY, byte[] Png) : ScreenMessage;
    public sealed record Viewers(IReadOnlyList<string> Names) : ScreenMessage;
    public sealed record MovedAway(string To) : ScreenMessage;
    public sealed record MicrophoneState(ScreenMicrophoneState State) : ScreenMessage;
    public sealed record SoundState(ScreenSoundState State) : ScreenMessage;
    public sealed record SoundPacket(byte[] Packet) : ScreenMessage;

    // Viewer → Mac
    public sealed record Hello(ScreenHello Value) : ScreenMessage;
    public sealed record Ack(uint Number) : ScreenMessage;
    public sealed record Pointer(ushort X, ushort Y, byte Buttons) : ScreenMessage;
    /// <summary>Stream pixels at the pointer; positive <c>Dy</c> brings earlier content into view.</summary>
    public sealed record Scroll(short Dx, short Dy) : ScreenMessage;
    public sealed record Key(uint Keysym, byte Modifiers) : ScreenMessage;
    public sealed record Text(string Value) : ScreenMessage;
    public sealed record Clipboard(string Value) : ScreenMessage;
    public sealed record KeyframeRequest : ScreenMessage;
    public sealed record Copy : ScreenMessage;
    public sealed record Curtain(bool Hidden) : ScreenMessage;
    public sealed record UseHere : ScreenMessage;
    public sealed record Gesture(ScreenGesture Kind, ScreenGesturePhase Phase, double Value) : ScreenMessage;
    public sealed record Microphone(bool On) : ScreenMessage;
    public sealed record Voice(byte[] Samples) : ScreenMessage;
    public sealed record Sound(bool On) : ScreenMessage;
    public sealed record Function(bool Down) : ScreenMessage;
}

/// <summary>The stream broke its rules: a payload over its limit, or one that doesn't parse.</summary>
public sealed class ScreenWireException(bool tooLarge) : IOException(tooLarge ? "A screen message was too large." : "A screen message was malformed.")
{
    public bool TooLarge { get; } = tooLarge;
}

/// <summary>
/// The Mac's own screen stream (a port of ScreenVideoWire.swift): after <c>screenVideoReady</c> the connection carries
/// messages of one type byte, a 4-byte big-endian payload length and the payload, both ways.
/// </summary>
public static class ScreenVideoWire
{
    /// <summary>Largest payload either side accepts (a keyframe of a big screen fits easily).</summary>
    public const int MaxPayload = 16 << 20;
    /// <summary>Largest <c>text</c> a viewer sends in one message; longer text goes in several (<see cref="TextPieces"/>).</summary>
    public const int MaxTextPayload = 4 << 10;
    public const int MaxClipboardPayload = 64 << 10;
    internal const int MaxEventPayload = 64;
    /// <summary>Text up to this many UTF-16 units the Mac types as key presses.</summary>
    public const int TypedAsKeys = 64;
    /// <summary>A viewer's voice: 16-bit little-endian mono at this rate, at most <see cref="MaxVoicePayload"/> a message.</summary>
    public const int VoiceSampleRate = 16_000;
    public const int MaxVoicePayload = 8 << 10;

    internal static class Kind
    {
        public const byte Format = 1, Frame = 2, Copied = 3, Curtained = 4, Fitted = 5, Cursor = 6, CursorShape = 7, Viewers = 8, MovedAway = 9;
        public const byte MicrophoneState = 10, SoundState = 11, SoundPacket = 12;
        public const byte Hello = 16, Ack = 17, Pointer = 18, Scroll = 19, Key = 20, Text = 21, Clipboard = 22, KeyframeRequest = 23, Copy = 24, Curtain = 25;
        public const byte UseHere = 26, Gesture = 27, Microphone = 28, Voice = 29, Function = 30, Sound = 31;

        public static bool IsKnown(byte type) => type is >= Format and <= SoundPacket or >= Hello and <= Sound;
    }

    public static byte[] Encode(ScreenMessage message)
    {
        var p = new List<byte>(16);
        void U16(int v) { var c = (ushort)Math.Clamp(v, 0, ushort.MaxValue); p.Add((byte)(c >> 8)); p.Add((byte)c); }
        void U32(uint v) { p.Add((byte)(v >> 24)); p.Add((byte)(v >> 16)); p.Add((byte)(v >> 8)); p.Add((byte)v); }
        void Bytes(ReadOnlySpan<byte> b) { foreach (var x in b) p.Add(x); }
        void Bool(bool b) => p.Add(b ? (byte)1 : (byte)0);
        byte kind;
        switch (message)
        {
            case ScreenMessage.Format f:
                kind = Kind.Format;
                p.Add((byte)f.Codec); U16(f.Width); U16(f.Height);
                p.Add((byte)Math.Min(f.ParameterSets.Count, 255));
                foreach (var set in f.ParameterSets.Take(255)) { U16(set.Length); Bytes(set); }
                break;
            case ScreenMessage.Frame f:
                kind = Kind.Frame;
                U32(f.Number); Bool(f.Keyframe); Bytes(f.Data);
                break;
            case ScreenMessage.Copied c:
                kind = Kind.Copied;
                switch (c.Result)
                {
                    case ScreenCopyResult.Text t: p.Add(0); Bytes(Encoding.UTF8.GetBytes(t.Value)); break;
                    case ScreenCopyResult.TooLong: p.Add(2); break;
                    case ScreenCopyResult.NotText: p.Add(3); break;
                    default: p.Add(1); break;
                }
                break;
            case ScreenMessage.Hello h:
                kind = Kind.Hello;
                U16(h.Value.Width); U16(h.Value.Height); p.Add((byte)h.Value.Fit); p.Add((byte)h.Value.Codecs);
                p.Add((byte)Math.Clamp(h.Value.Fps, 0, 255)); p.Add((byte)h.Value.Quality); p.Add((byte)Math.Clamp(h.Value.Space, 0, 255));
                break;
            case ScreenMessage.Viewers v:
                kind = Kind.Viewers;
                var kept = v.Names.Take(16).Select(n => Encoding.UTF8.GetBytes(Prefix(n, 64)) is var b && b.Length > 255 ? b[..255] : b).ToList();
                p.Add((byte)kept.Count);
                foreach (var name in kept) { p.Add((byte)name.Length); Bytes(name); }
                break;
            case ScreenMessage.MovedAway m:
                kind = Kind.MovedAway;
                Bytes(Encoding.UTF8.GetBytes(Prefix(m.To, 64)));
                break;
            case ScreenMessage.UseHere: kind = Kind.UseHere; break;
            case ScreenMessage.Gesture g:
                kind = Kind.Gesture;
                p.Add((byte)g.Kind); p.Add((byte)g.Phase);
                // Ten-thousandths: plenty for a step of a pinch, and room for a whole turn.
                var scaled = Math.Round(g.Value * 10_000, MidpointRounding.AwayFromZero);
                U32(unchecked((uint)(double.IsNaN(scaled) ? 0 : (int)Math.Clamp(scaled, int.MinValue, int.MaxValue))));
                break;
            case ScreenMessage.Fitted f: kind = Kind.Fitted; p.Add((byte)f.Fit); break;
            case ScreenMessage.Cursor c: kind = Kind.Cursor; U16(c.X); U16(c.Y); Bool(c.Visible); break;
            case ScreenMessage.CursorShape s:
                kind = Kind.CursorShape;
                U16(s.Width); U16(s.Height); U16(s.HotX); U16(s.HotY); Bytes(s.Png);
                break;
            case ScreenMessage.Ack a: kind = Kind.Ack; U32(a.Number); break;
            case ScreenMessage.Pointer pt: kind = Kind.Pointer; U16(pt.X); U16(pt.Y); p.Add(pt.Buttons); break;
            case ScreenMessage.Scroll s: kind = Kind.Scroll; U16(unchecked((ushort)s.Dx)); U16(unchecked((ushort)s.Dy)); break;
            case ScreenMessage.Key k: kind = Kind.Key; U32(k.Keysym); p.Add(k.Modifiers); break;
            case ScreenMessage.Text t: kind = Kind.Text; Bytes(Encoding.UTF8.GetBytes(t.Value)); break;
            case ScreenMessage.Clipboard c: kind = Kind.Clipboard; Bytes(Encoding.UTF8.GetBytes(c.Value)); break;
            case ScreenMessage.KeyframeRequest: kind = Kind.KeyframeRequest; break;
            case ScreenMessage.Copy: kind = Kind.Copy; break;
            case ScreenMessage.Curtained c: kind = Kind.Curtained; Bool(c.Hidden); break;
            case ScreenMessage.Curtain c: kind = Kind.Curtain; Bool(c.Hidden); break;
            case ScreenMessage.Microphone m: kind = Kind.Microphone; Bool(m.On); break;
            case ScreenMessage.Voice v: kind = Kind.Voice; Bytes(v.Samples); break;
            case ScreenMessage.Function f: kind = Kind.Function; Bool(f.Down); break;
            case ScreenMessage.Sound s: kind = Kind.Sound; Bool(s.On); break;
            case ScreenMessage.SoundState s: kind = Kind.SoundState; p.Add((byte)s.State); break;
            case ScreenMessage.SoundPacket s: kind = Kind.SoundPacket; Bytes(s.Packet); break;
            case ScreenMessage.MicrophoneState m: kind = Kind.MicrophoneState; p.Add((byte)m.State); break;
            default: throw new ArgumentException("Unknown screen message.", nameof(message));
        }
        var output = new byte[5 + p.Count];
        output[0] = kind;
        BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(1), (uint)p.Count);
        p.CopyTo(output, 5);
        return output;
    }

    /// <summary>The first <paramref name="count"/> characters (grapheme clusters) of <paramref name="text"/>.</summary>
    private static string Prefix(string text, int count)
    {
        var e = StringInfo.GetTextElementEnumerator(text);
        var taken = 0;
        var end = 0;
        while (taken < count && e.MoveNext()) { taken++; end = e.ElementIndex + ((string)e.Current).Length; }
        return text[..end];
    }

    /// <summary>
    /// <paramref name="text"/> in pieces of at most <paramref name="maxBytes"/> of UTF-8 each, split between characters (a
    /// single character longer than that, between its scalars), so a long paste still fits <see cref="MaxTextPayload"/> a message.
    /// </summary>
    public static IReadOnlyList<string> TextPieces(string text, int maxBytes = MaxTextPayload)
    {
        if (Encoding.UTF8.GetByteCount(text) <= maxBytes) return text.Length == 0 ? [] : [text];
        var pieces = new List<string>();
        var piece = new StringBuilder();
        var pieceBytes = 0;
        void Add(string part, int bytes)
        {
            if (pieceBytes + bytes > maxBytes && piece.Length > 0) { pieces.Add(piece.ToString()); piece.Clear(); pieceBytes = 0; }
            piece.Append(part);
            pieceBytes += bytes;
        }
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var character = (string)e.Current;
            var bytes = Encoding.UTF8.GetByteCount(character);
            if (bytes <= maxBytes) Add(character, bytes);
            else foreach (var rune in character.EnumerateRunes()) Add(rune.ToString(), rune.Utf8SequenceLength);
        }
        if (piece.Length > 0) pieces.Add(piece.ToString());
        return pieces;
    }

    /// <summary>The most a payload of message type <paramref name="type"/> from <paramref name="sender"/> may be.</summary>
    internal static int MaxPayloadOf(byte type, ScreenSender sender)
    {
        // What the Mac copied is held to what a viewer may paste (and a status byte).
        if (sender != ScreenSender.Phone) return type == Kind.Copied ? MaxClipboardPayload + 1 : MaxPayload;
        return type switch
        {
            Kind.Text => MaxTextPayload,
            Kind.Clipboard => MaxClipboardPayload,
            Kind.Voice => MaxVoicePayload,
            // A type added later: skipped, but not buffered without bound either.
            _ when !Kind.IsKnown(type) => MaxClipboardPayload,
            _ => MaxEventPayload,
        };
    }

    /// <summary>
    /// Splits a byte stream into messages. Unknown types are skipped, so either side can add some later. Each payload's
    /// length is checked against its type's limit from the 5-byte header, before it is buffered.
    /// </summary>
    public sealed class Reader(ScreenSender sender = ScreenSender.Mac)
    {
        private byte[] _buffer = new byte[4096];
        private int _start, _count;

        /// <summary>The messages complete so far; throws <see cref="ScreenWireException"/> on a payload over its limit or one that doesn't parse.</summary>
        public IReadOnlyList<ScreenMessage> Append(ReadOnlySpan<byte> data)
        {
            Store(data);
            var messages = new List<ScreenMessage>();
            while (_count >= 5)
            {
                var header = _buffer.AsSpan(_start, 5);
                var type = header[0];
                var length = BinaryPrimitives.ReadUInt32BigEndian(header[1..]);
                if (length > (uint)MaxPayloadOf(type, sender)) throw new ScreenWireException(tooLarge: true);
                if (_count < 5 + (int)length) break;
                var payload = _buffer.AsSpan(_start + 5, (int)length);
                if (Kind.IsKnown(type)) messages.Add(Decode(type, payload));
                _start += 5 + (int)length;
                _count -= 5 + (int)length;
            }
            if (_count == 0) _start = 0;
            return messages;
        }

        private void Store(ReadOnlySpan<byte> data)
        {
            if (data.IsEmpty) return;
            if (_start + _count + data.Length > _buffer.Length)
            {
                if (_count + data.Length <= _buffer.Length) Buffer.BlockCopy(_buffer, _start, _buffer, 0, _count);
                else
                {
                    var bigger = new byte[Math.Max(_buffer.Length * 2, _count + data.Length)];
                    Buffer.BlockCopy(_buffer, _start, bigger, 0, _count);
                    _buffer = bigger;
                }
                _start = 0;
            }
            data.CopyTo(_buffer.AsSpan(_start + _count));
            _count += data.Length;
        }
    }

    private static void Need(ReadOnlySpan<byte> p, int count) { if (p.Length < count) throw new ScreenWireException(tooLarge: false); }
    private static ushort U16(ReadOnlySpan<byte> p, int at) => BinaryPrimitives.ReadUInt16BigEndian(p[at..]);
    private static uint U32(ReadOnlySpan<byte> p, int at) => BinaryPrimitives.ReadUInt32BigEndian(p[at..]);
    private static string Utf8(ReadOnlySpan<byte> b) => Encoding.UTF8.GetString(b);

    internal static ScreenMessage Decode(byte type, ReadOnlySpan<byte> p)
    {
        switch (type)
        {
            case Kind.Format:
            {
                Need(p, 6);
                if (p[0] > (byte)ScreenCodec.Hevc) throw new ScreenWireException(tooLarge: false);
                var offset = 6;
                var sets = new List<byte[]>();
                for (var i = 0; i < p[5]; i++)
                {
                    Need(p, offset + 2);
                    var length = U16(p, offset);
                    Need(p, offset + 2 + length);
                    sets.Add(p.Slice(offset + 2, length).ToArray());
                    offset += 2 + length;
                }
                return new ScreenMessage.Format((ScreenCodec)p[0], U16(p, 1), U16(p, 3), sets);
            }
            case Kind.Frame:
                Need(p, 5);
                return new ScreenMessage.Frame(U32(p, 0), (p[4] & 1) != 0, p[5..].ToArray());
            case Kind.Hello:
                Need(p, 9);
                // A fit or quality added later reads as the first; H.264 is always decodable.
                return new ScreenMessage.Hello(new ScreenHello(U16(p, 0), U16(p, 2), p[4] <= (byte)ScreenFit.Device ? (ScreenFit)p[4] : ScreenFit.Mac,
                    (ScreenCodecs)p[5] | ScreenCodecs.H264, Math.Clamp((int)p[6], 15, 120),
                    p[7] <= (byte)ScreenQuality.Fast ? (ScreenQuality)p[7] : ScreenQuality.Sharp, Math.Clamp((int)p[8], 50, 200)));
            case Kind.Viewers:
            {
                Need(p, 1);
                var names = new List<string>();
                var offset = 1;
                for (var i = 0; i < p[0]; i++)
                {
                    Need(p, offset + 1);
                    var length = p[offset];
                    Need(p, offset + 1 + length);
                    names.Add(Utf8(p.Slice(offset + 1, length)));
                    offset += 1 + length;
                }
                return new ScreenMessage.Viewers(names);
            }
            case Kind.MovedAway: return new ScreenMessage.MovedAway(Utf8(p));
            case Kind.UseHere: return new ScreenMessage.UseHere();
            case Kind.Gesture:
                Need(p, 6);
                if (p[0] > (byte)ScreenGesture.Rotate || p[1] is not (1 or 2 or 4 or 8)) throw new ScreenWireException(tooLarge: false);
                return new ScreenMessage.Gesture((ScreenGesture)p[0], (ScreenGesturePhase)p[1], unchecked((int)U32(p, 2)) / 10_000.0);
            case Kind.Fitted:
                Need(p, 1);
                return new ScreenMessage.Fitted(p[0] <= (byte)ScreenFit.Device ? (ScreenFit)p[0] : ScreenFit.Mac);
            case Kind.Cursor:
                Need(p, 5);
                return new ScreenMessage.Cursor(U16(p, 0), U16(p, 2), (p[4] & 1) != 0);
            case Kind.CursorShape:
                Need(p, 8);
                return new ScreenMessage.CursorShape(U16(p, 0), U16(p, 2), U16(p, 4), U16(p, 6), p[8..].ToArray());
            case Kind.Ack: Need(p, 4); return new ScreenMessage.Ack(U32(p, 0));
            case Kind.Pointer: Need(p, 5); return new ScreenMessage.Pointer(U16(p, 0), U16(p, 2), p[4]);
            case Kind.Scroll: Need(p, 4); return new ScreenMessage.Scroll(unchecked((short)U16(p, 0)), unchecked((short)U16(p, 2)));
            case Kind.Key: Need(p, 5); return new ScreenMessage.Key(U32(p, 0), p[4]);
            case Kind.Text: return new ScreenMessage.Text(Utf8(p));
            case Kind.Clipboard: return new ScreenMessage.Clipboard(Utf8(p));
            case Kind.Copied:
                Need(p, 1);
                return new ScreenMessage.Copied(p[0] switch
                {
                    0 => new ScreenCopyResult.Text(Utf8(p[1..])),
                    2 => new ScreenCopyResult.TooLong(),
                    3 => new ScreenCopyResult.NotText(),
                    // A status added later reads as nothing copied.
                    _ => new ScreenCopyResult.Nothing(),
                });
            case Kind.KeyframeRequest: return new ScreenMessage.KeyframeRequest();
            case Kind.Copy: return new ScreenMessage.Copy();
            case Kind.Curtained: Need(p, 1); return new ScreenMessage.Curtained(p[0] == 1);
            case Kind.Curtain: Need(p, 1); return new ScreenMessage.Curtain(p[0] == 1);
            case Kind.Microphone: Need(p, 1); return new ScreenMessage.Microphone(p[0] == 1);
            case Kind.Function: Need(p, 1); return new ScreenMessage.Function(p[0] == 1);
            case Kind.Sound: Need(p, 1); return new ScreenMessage.Sound(p[0] == 1);
            case Kind.SoundState:
                Need(p, 1);
                return new ScreenMessage.SoundState(p[0] is 0 or 1 or 3 ? (ScreenSoundState)p[0] : ScreenSoundState.Failed);
            case Kind.SoundPacket: return new ScreenMessage.SoundPacket(p.ToArray());
            // Whole samples only.
            case Kind.Voice: return new ScreenMessage.Voice(p[..(p.Length & ~1)].ToArray());
            case Kind.MicrophoneState:
                Need(p, 1);
                // A state added later reads as not taking the voice.
                return new ScreenMessage.MicrophoneState(p[0] <= 3 ? (ScreenMicrophoneState)p[0] : ScreenMicrophoneState.Failed);
            default: throw new ScreenWireException(tooLarge: false);
        }
    }
}
