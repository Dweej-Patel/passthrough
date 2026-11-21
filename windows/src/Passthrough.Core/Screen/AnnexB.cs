using System.Buffers;
using System.Buffers.Binary;

namespace Passthrough.Core.Screen;

/// <summary>
/// A frame's NAL units after 4-byte big-endian lengths (AVCC or HVCC, as the Mac sends them) rewritten after start codes
/// (Annex B, as Media Foundation's decoders take them). In-band parameter sets are dropped and, on a keyframe, the ones
/// <c>format</c> announced (and that were checked) are written first, so a decoder only ever sees sizes that were checked.
/// </summary>
public static class AnnexB
{
    public const int MaxUnits = 4096;
    private static ReadOnlySpan<byte> StartCode => [0, 0, 0, 1];

    /// <summary>Whether a NAL unit's header names a parameter set (H.264 SPS, PPS; HEVC VPS, SPS, PPS).</summary>
    public static bool IsParameterSet(ScreenCodec codec, byte header) =>
        codec == ScreenCodec.Hevc ? ((header >> 1) & 0x3F) is >= 32 and <= 34 : (header & 0x1F) is 7 or 8;

    /// <summary>
    /// The frame in Annex B, in a pooled buffer the caller disposes; null when nothing was left to decode (a frame of
    /// parameter sets only). Throws <see cref="MalformedStreamException"/> on a zero length, a length past the end, or
    /// more than <see cref="MaxUnits"/> units.
    /// </summary>
    public static IMemoryOwner<byte>? Convert(ReadOnlySpan<byte> frame, ScreenCodec codec, bool keyframe, IReadOnlyList<byte[]> parameterSets)
    {
        if (frame.IsEmpty) throw new MalformedStreamException("An empty frame.");
        var units = 0;
        var kept = 0;
        for (var offset = 0; offset < frame.Length;)
        {
            if (frame.Length - offset < 4) throw new MalformedStreamException("A NAL length past the end.");
            var length = BinaryPrimitives.ReadUInt32BigEndian(frame[offset..]);
            offset += 4;
            if (length == 0 || length > (uint)(frame.Length - offset)) throw new MalformedStreamException("A NAL length past the end.");
            if (++units > MaxUnits) throw new MalformedStreamException("Too many NAL units.");
            if (!IsParameterSet(codec, frame[offset])) kept += 4 + (int)length;
            offset += (int)length;
        }
        if (kept == 0) return null;
        var size = kept + (keyframe ? parameterSets.Sum(s => 4 + s.Length) : 0);
        var owner = new Pooled(size);
        var output = owner.Span;
        var at = 0;
        if (keyframe)
            foreach (var set in parameterSets)
            {
                StartCode.CopyTo(output[at..]);
                set.CopyTo(output[(at + 4)..]);
                at += 4 + set.Length;
            }
        for (var offset = 0; offset < frame.Length;)
        {
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(frame[offset..]);
            offset += 4;
            var unit = frame.Slice(offset, length);
            offset += length;
            if (IsParameterSet(codec, unit[0])) continue;
            StartCode.CopyTo(output[at..]);
            unit.CopyTo(output[(at + 4)..]);
            at += 4 + length;
        }
        return owner;
    }

    private sealed class Pooled(int length) : IMemoryOwner<byte>
    {
        private byte[]? _array = ArrayPool<byte>.Shared.Rent(length);

        public Memory<byte> Memory => _array is { } a ? a.AsMemory(0, length) : throw new ObjectDisposedException(nameof(Pooled));
        internal Span<byte> Span => _array.AsSpan(0, length);

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _array, null) is { } a) ArrayPool<byte>.Shared.Return(a);
        }
    }
}

/// <summary>The screen stream broke a rule this viewer checks (an impossible size, a bad parameter set, a broken frame).</summary>
public sealed class MalformedStreamException(string message) : IOException(message);
