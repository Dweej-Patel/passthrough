namespace Passthrough.Core.Tests.Screen;

/// <summary>Writes H.264 sequence parameter sets bit by bit, as an encoder does, with emulation prevention.</summary>
internal static class SpsBuilder
{
    public static byte[] Sps(int width, int height, int profile = 100, int level = 51, int chroma = 1, int bitDepth = 8, bool frameOnly = true,
        bool? fullRange = null, int matrix = 1, bool scalingMatrix = false, int pocType = 0)
    {
        var w = new Bits();
        w.U(8, profile);
        w.U(8, profile == 66 ? 0xC0 : 0);
        w.U(8, level);
        w.Ue(0);
        if (profile is 100 or 110 or 122 or 244)
        {
            w.Ue(chroma);
            if (chroma == 3) w.U(1, 0);
            w.Ue(bitDepth - 8);
            w.Ue(bitDepth - 8);
            w.U(1, 0);
            w.U(1, scalingMatrix ? 1 : 0);
            if (scalingMatrix)
                for (var i = 0; i < 8; i++)
                {
                    w.U(1, i == 0 ? 1 : 0);
                    if (i == 0) for (var j = 0; j < 16; j++) w.Se(j == 0 ? 8 : 0); // a flat list, written out
                }
        }
        w.Ue(0); // log2_max_frame_num_minus4
        w.Ue(pocType);
        if (pocType == 0) w.Ue(2);
        w.Ue(1); // max_num_ref_frames
        w.U(1, 0);
        var mbsWide = (width + 15) / 16;
        var unitsHigh = (height + 15) / 16 / (frameOnly ? 1 : 2) + (frameOnly ? 0 : ((height + 15) / 16) % 2);
        w.Ue(mbsWide - 1);
        w.Ue(unitsHigh - 1);
        w.U(1, frameOnly ? 1 : 0);
        if (!frameOnly) w.U(1, 0);
        w.U(1, 1);
        var cropRight = (mbsWide * 16 - width) / 2;
        var cropBottom = (unitsHigh * 16 * (frameOnly ? 1 : 2) - height) / (frameOnly ? 2 : 4);
        var crop = cropRight != 0 || cropBottom != 0;
        w.U(1, crop ? 1 : 0);
        if (crop) { w.Ue(0); w.Ue(cropRight); w.Ue(0); w.Ue(cropBottom); }
        w.U(1, fullRange is null ? 0 : 1);
        if (fullRange is { } full)
        {
            w.U(1, 0); // aspect ratio
            w.U(1, 0); // overscan
            w.U(1, 1);
            w.U(3, 5);
            w.U(1, full ? 1 : 0);
            w.U(1, 1);
            w.U(8, 1);
            w.U(8, 1);
            w.U(8, matrix);
            w.U(1, 0); // chroma loc
            w.U(1, 0); // timing
            w.U(1, 0);
            w.U(1, 0);
            w.U(1, 0); // pic_struct
            w.U(1, 0); // bitstream restriction
        }
        w.U(1, 1); // rbsp stop bit
        return [0x67, .. Escape(w.ToArray())];
    }

    private static byte[] Escape(byte[] rbsp)
    {
        var output = new List<byte>();
        var zeros = 0;
        foreach (var b in rbsp)
        {
            if (zeros >= 2 && b <= 3) { output.Add(3); zeros = 0; }
            output.Add(b);
            zeros = b == 0 ? zeros + 1 : 0;
        }
        return [.. output];
    }

    private sealed class Bits
    {
        private readonly List<bool> _bits = [];
        public void U(int count, int value) { for (var i = count - 1; i >= 0; i--) _bits.Add(((value >> i) & 1) == 1); }
        public void Ue(int value)
        {
            var v = value + 1;
            var length = 32 - int.LeadingZeroCount(v);
            U(length - 1, 0);
            U(length, v);
        }
        public void Se(int value) => Ue(value <= 0 ? -2 * value : 2 * value - 1);
        public byte[] ToArray()
        {
            var bytes = new byte[(_bits.Count + 7) / 8];
            for (var i = 0; i < _bits.Count; i++) if (_bits[i]) bytes[i / 8] |= (byte)(0x80 >> (i % 8));
            return bytes;
        }
    }
}
