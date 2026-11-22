namespace Passthrough.Media;

/// <summary>
/// NV12 to BGRA (alpha 255) with BT.709 coefficients, as the Mac encodes (VideoEncoder.swift: BT.709 primaries, transfer
/// and matrix, from video-range capture): video range by default, full range when the SPS says so. Rows in parallel,
/// fixed point, no allocation.
/// </summary>
public static class Nv12ToBgra
{
    /// <summary>Converts <paramref name="frame"/> into <paramref name="bgra"/>, <paramref name="stride"/> bytes a row (at least width × 4).</summary>
    public static void Convert(Nv12Frame frame, Span<byte> bgra, int stride, bool fullRange = false) =>
        Convert(frame.Y, frame.UV, frame.Width, frame.Height, frame.Pitch, bgra, stride, fullRange);

    public static unsafe void Convert(ReadOnlySpan<byte> y, ReadOnlySpan<byte> uv, int width, int height, int pitch, Span<byte> bgra, int stride, bool fullRange = false)
    {
        if (width <= 0 || height <= 0) return;
        if (pitch < width || stride < width * 4) throw new ArgumentException("Rows shorter than the picture.");
        // A chroma row holds a U and V pair for every two pixels, the last one included when the width is odd.
        if (pitch < (width + 1) / 2 * 2 || y.Length < pitch * (height - 1) + width || uv.Length < pitch * ((height + 1) / 2 - 1) + (width + 1) / 2 * 2
            || bgra.Length < stride * (height - 1) + width * 4)
            throw new ArgumentException("Planes shorter than the picture.");
        // Coefficients × 1024. Video range: Y 16…235, chroma 16…240.
        int yScale, yOffset, rv, gu, gv, bu;
        if (fullRange) (yScale, yOffset, rv, gu, gv, bu) = (1024, 0, 1613, 192, 479, 1900);
        else (yScale, yOffset, rv, gu, gv, bu) = (1192, 16, 1836, 218, 546, 2163);
        fixed (byte* yp = y, uvp = uv, op = bgra)
        {
            var (ya, uva, oa) = ((nint)yp, (nint)uvp, (nint)op);
            Parallel.For(0, (height + 1) / 2, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount / 2) }, pair =>
            {
                var yRow0 = (byte*)ya;
                var uvRow = (byte*)uva + (long)pair * pitch;
                for (var row = pair * 2; row < Math.Min(height, pair * 2 + 2); row++)
                {
                    var yRow = yRow0 + (long)row * pitch;
                    var o = (byte*)oa + (long)row * stride;
                    for (var x = 0; x < width; x++)
                    {
                        var c = (yRow[x] - yOffset) * yScale;
                        var u = uvRow[x & ~1] - 128;
                        var v = uvRow[(x & ~1) + 1] - 128;
                        o[0] = Clamp((c + bu * u + 512) >> 10);
                        o[1] = Clamp((c - gu * u - gv * v + 512) >> 10);
                        o[2] = Clamp((c + rv * v + 512) >> 10);
                        o[3] = 255;
                        o += 4;
                    }
                }
            });
        }
    }

    private static byte Clamp(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);
}
