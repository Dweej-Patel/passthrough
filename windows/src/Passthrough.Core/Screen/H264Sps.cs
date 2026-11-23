namespace Passthrough.Core.Screen;

/// <summary>What this viewer reads from an H.264 sequence parameter set before a decoder sees it.</summary>
public sealed record H264Sps(int Profile, int Level, int ChromaFormat, int BitDepth, bool FrameOnly, int Width, int Height,
    bool? FullRange, int? Matrix)
{
    /// <summary>Baseline, Main and High: what the Mac's encoder makes (Constrained High) and Media Foundation decodes.</summary>
    public static readonly IReadOnlySet<int> AllowedProfiles = new HashSet<int> { 66, 77, 100 };

    /// <summary>Whether this stream is one a decoder here is given: an allowed profile, 4:2:0, 8 bits, frames only.</summary>
    public bool IsAcceptable => AllowedProfiles.Contains(Profile) && ChromaFormat == 1 && BitDepth == 8 && FrameOnly;

    /// <summary>
    /// Parses an SPS NAL unit (header byte first, emulation-prevention bytes in place); null when it isn't one or doesn't
    /// parse. Never throws.
    /// </summary>
    public static H264Sps? TryParse(ReadOnlySpan<byte> nal)
    {
        if (nal.Length < 4 || (nal[0] & 0x1F) != 7 || (nal[0] & 0x80) != 0) return null;
        var rbsp = Unescape(nal[1..]);
        var r = new BitReader(rbsp);
        try
        {
            var profile = r.Bits(8);
            r.Bits(8); // constraint flags
            var level = r.Bits(8);
            if (r.Ue() > 31) return null; // seq_parameter_set_id
            int chroma = 1, depthLuma = 8, depthChroma = 8;
            if (profile is 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128 or 138 or 139 or 134 or 135)
            {
                chroma = r.Ue();
                if (chroma > 3) return null;
                if (chroma == 3) r.Bits(1); // separate_colour_plane_flag
                depthLuma = 8 + r.Ue();
                depthChroma = 8 + r.Ue();
                r.Bits(1); // qpprime_y_zero_transform_bypass_flag
                if (r.Bits(1) == 1) // seq_scaling_matrix_present_flag
                    for (var i = 0; i < (chroma != 3 ? 8 : 12); i++)
                        if (r.Bits(1) == 1) SkipScalingList(ref r, i < 6 ? 16 : 64);
            }
            if (r.Ue() > 12) return null; // log2_max_frame_num_minus4
            var pocType = r.Ue();
            if (pocType == 0) { if (r.Ue() > 12) return null; }
            else if (pocType == 1)
            {
                r.Bits(1);
                r.Se();
                r.Se();
                var cycle = r.Ue();
                if (cycle > 255) return null;
                for (var i = 0; i < cycle; i++) r.Se();
            }
            else if (pocType != 2) return null;
            r.Ue(); // max_num_ref_frames
            r.Bits(1); // gaps_in_frame_num_value_allowed_flag
            var widthMbs = r.Ue() + 1;
            var heightUnits = r.Ue() + 1;
            if (widthMbs > 1024 || heightUnits > 1024) return null;
            var frameOnly = r.Bits(1) == 1;
            if (!frameOnly) r.Bits(1); // mb_adaptive_frame_field_flag
            r.Bits(1); // direct_8x8_inference_flag
            int cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
            if (r.Bits(1) == 1)
            {
                cropLeft = r.Ue();
                cropRight = r.Ue();
                cropTop = r.Ue();
                cropBottom = r.Ue();
            }
            bool? fullRange = null;
            int? matrix = null;
            if (r.Bits(1) == 1) // vui_parameters_present_flag
            {
                if (r.Bits(1) == 1 && r.Bits(8) == 255) { r.Bits(16); r.Bits(16); } // aspect ratio, extended SAR
                if (r.Bits(1) == 1) r.Bits(1); // overscan
                if (r.Bits(1) == 1) // video_signal_type_present_flag
                {
                    r.Bits(3);
                    fullRange = r.Bits(1) == 1;
                    if (r.Bits(1) == 1)
                    {
                        r.Bits(8);
                        r.Bits(8);
                        matrix = r.Bits(8);
                    }
                }
            }
            // Cropping is in 2-pixel units for 4:2:0 (and 4:2:2 across); 1 for monochrome and 4:4:4.
            var cropX = chroma is 1 or 2 ? 2 : 1;
            var cropY = (chroma == 1 ? 2 : 1) * (frameOnly ? 1 : 2);
            var width = widthMbs * 16 - (cropLeft + cropRight) * cropX;
            var height = heightUnits * 16 * (frameOnly ? 1 : 2) - (cropTop + cropBottom) * cropY;
            if (width <= 0 || height <= 0) return null;
            return new H264Sps(profile, level, chroma, depthLuma == depthChroma ? depthLuma : -1, frameOnly, width, height, fullRange, matrix);
        }
        catch (EndOfSpsException) { return null; }
    }

    private static void SkipScalingList(ref BitReader r, int size)
    {
        int last = 8, next = 8;
        for (var j = 0; j < size; j++)
        {
            if (next != 0) next = (last + r.Se() + 256) % 256;
            last = next == 0 ? last : next;
        }
    }

    /// <summary>The payload with each <c>00 00 03</c> read as <c>00 00</c>.</summary>
    internal static byte[] Unescape(ReadOnlySpan<byte> data)
    {
        var output = new List<byte>(data.Length);
        var zeros = 0;
        foreach (var b in data)
        {
            if (zeros >= 2 && b == 3) { zeros = 0; continue; }
            output.Add(b);
            zeros = b == 0 ? zeros + 1 : 0;
        }
        return [.. output];
    }

    private sealed class EndOfSpsException : Exception;

    private ref struct BitReader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> _data = data;
        private int _bit;

        public int Bits(int count)
        {
            var value = 0;
            for (var i = 0; i < count; i++)
            {
                if (_bit >= _data.Length * 8) throw new EndOfSpsException();
                value = (value << 1) | ((_data[_bit >> 3] >> (7 - (_bit & 7))) & 1);
                _bit++;
            }
            return value;
        }

        /// <summary>Unsigned Exp-Golomb, at most 31 bits of value (more is no real SPS).</summary>
        public int Ue()
        {
            var zeros = 0;
            while (Bits(1) == 0)
                if (++zeros > 30) throw new EndOfSpsException();
            return (1 << zeros) - 1 + Bits(zeros);
        }

        public int Se()
        {
            var k = Ue();
            return (k & 1) == 1 ? (k + 1) / 2 : -(k / 2);
        }
    }
}
