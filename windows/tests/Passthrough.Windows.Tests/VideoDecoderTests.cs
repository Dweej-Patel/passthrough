using System.Runtime.InteropServices;
using Passthrough.Core.Screen;
using Passthrough.Media;
using Passthrough.Media.Interop;
using Xunit;
using Xunit.Abstractions;

namespace Passthrough.Windows.Tests;

/// <summary>
/// The decoder on this PC's own Media Foundation: a short H.264 stream made here by Microsoft's H.264 encoder goes
/// through the same checks and conversion as the Mac's (SPS parsed and sized, AVCC to Annex B with the checked sets)
/// and decodes to NV12 of the right size and brightness, in hardware when there is a GPU and in software. Where Media
/// Foundation or its H.264 codecs are missing (Windows N, Server Core) the test says so and passes.
/// </summary>
public sealed class VideoDecoderTests(ITestOutputHelper output)
{
    private const int Width = 320, Height = 180; // 180 isn't a multiple of 16: the SPS crops and the decoder pads

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void AStreamMadeByMediaFoundationDecodesToTheRightPicture(bool hardware)
    {
        if (!VideoDecoder.Start()) { output.WriteLine("No Media Foundation here: skipped."); return; }
        List<byte[]> encoded;
        try { encoded = Encode(Width, Height, frames: 6, luma: 160); }
        catch (Exception e) when (e is COMException or InvalidCastException) { output.WriteLine($"No H.264 encoder here ({e.Message}): skipped."); return; }

        // As the Mac sends it: parameter sets apart, frames as 4-byte lengths.
        var units = encoded.Select(SplitAnnexB).ToList();
        var sps = units.SelectMany(u => u).First(n => (n[0] & 0x1F) == 7);
        var pps = units.SelectMany(u => u).First(n => (n[0] & 0x1F) == 8);
        var parsed = H264Sps.TryParse(sps);
        Assert.NotNull(parsed);
        Assert.Equal((Width, Height), (parsed.Width, parsed.Height));
        IReadOnlyList<byte[]> sets = [sps, pps];
        ScreenVideoClient.CheckFormat(ScreenCodec.H264, Width, Height, sets, ScreenCodecs.H264);

        using var decoder = new VideoDecoder(ScreenCodec.H264, Width, Height, hardware);
        output.WriteLine($"Decoding in {(decoder.IsHardware ? "hardware" : "software")}.");
        var pictures = new List<Nv12Frame>();
        try
        {
            for (var i = 0; i < units.Count; i++)
            {
                var keyframe = units[i].Any(n => (n[0] & 0x1F) == 5);
                byte[] avcc = [.. units[i].SelectMany(n => new byte[] { (byte)(n.Length >> 24), (byte)(n.Length >> 16), (byte)(n.Length >> 8), (byte)n.Length }.Concat(n))];
                using var annexB = AnnexB.Convert(avcc, ScreenCodec.H264, keyframe, sets);
                if (annexB is null) continue;
                pictures.AddRange(decoder.Decode(annexB.Memory.Span, i + 1, keyframe));
            }
            pictures.AddRange(decoder.Finish());
            Assert.NotEmpty(pictures);
            foreach (var picture in pictures)
            {
                Assert.Equal((Width, Height), (picture.Width, picture.Height));
                Assert.InRange(picture.Y[picture.Pitch * (Height / 2) + Width / 2], 150, 170);
                Assert.InRange(picture.UV[picture.Pitch * (Height / 4) + Width / 2], 118, 138);
            }
            var bgra = new byte[Width * Height * 4];
            Nv12ToBgra.Convert(pictures[^1], bgra, Width * 4);
            var centre = (Height / 2 * Width + Width / 2) * 4;
            // Y 160 in video range is about 168 in RGB, grey.
            Assert.InRange(bgra[centre], 158, 178);
            Assert.InRange(Math.Abs(bgra[centre] - bgra[centre + 2]), 0, 10);
            Assert.Equal(255, bgra[centre + 3]);
        }
        finally { foreach (var p in pictures) p.Dispose(); }
    }

    /// <summary>Damaged slices after a good keyframe: pictures or a <see cref="DecodeException"/>, never anything else.</summary>
    [Fact]
    public void DamagedFramesGivePicturesOrADecodeError()
    {
        if (!VideoDecoder.Start()) return;
        List<byte[]> encoded;
        try { encoded = Encode(Width, Height, frames: 4, luma: 90); }
        catch (Exception e) when (e is COMException or InvalidCastException) { return; }
        var random = new Random(3);
        using var decoder = new VideoDecoder(ScreenCodec.H264, Width, Height, hardware: true);
        for (var round = 0; round < 40; round++)
        {
            var bytes = encoded[round % encoded.Count].ToArray();
            if (round >= encoded.Count)
                for (var i = 0; i < 1 + random.Next(8); i++) bytes[8 + random.Next(bytes.Length - 8)] = (byte)random.Next(256);
            try { foreach (var p in decoder.Decode(bytes, round + 1, round % encoded.Count == 0)) p.Dispose(); }
            catch (DecodeException) { decoder.Flush(); }
        }
    }

    [Fact]
    public void ASizeCoreWouldNotPassIsRefused()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new VideoDecoder(ScreenCodec.H264, 8, 8));
        Assert.Throws<ArgumentOutOfRangeException>(() => new VideoDecoder(ScreenCodec.H264, 4097, 720));
    }

    [Fact]
    public void TheHevcProbeAnswersEitherWay()
    {
        var codecs = VideoDecoder.Decodable();
        Assert.True(codecs.HasFlag(ScreenCodecs.H264));
        output.WriteLine($"HEVC decodable here: {codecs.HasFlag(ScreenCodecs.Hevc)}");
    }

    [Fact]
    public void ConversionUsesBt709VideoRange()
    {
        // 2×2 pixels: black (16), white (235), and pure red's YUV in BT.709 video range (63, 102, 240).
        byte[] y = [16, 235, 63, 63];
        byte[] uv = [128, 128];
        var bgra = new byte[16];
        Nv12ToBgra.Convert(y.AsSpan(0, 2), uv, 2, 1, 2, bgra, 8);
        Assert.Equal([0, 0, 0, 255, 255, 255, 255, 255], bgra[..8]);
        Nv12ToBgra.Convert(y.AsSpan(2, 2), (byte[])[102, 240], 2, 1, 2, bgra, 8);
        Assert.InRange(bgra[2], 250, 255); // red
        Assert.InRange(bgra[1], 0, 6);
        Assert.InRange(bgra[0], 0, 6);
        Assert.Throws<ArgumentException>(() => Nv12ToBgra.Convert(y, uv, 4, 4, 4, bgra, 16)); // planes too short
    }

    private static List<byte[]> SplitAnnexB(byte[] data)
    {
        var units = new List<byte[]>();
        var starts = new List<(int Start, int Code)>();
        for (var i = 0; i + 3 <= data.Length; i++)
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) { starts.Add((i + 3, i > 0 && data[i - 1] == 0 ? 4 : 3)); i += 2; }
        for (var k = 0; k < starts.Count; k++)
        {
            var end = k + 1 < starts.Count ? starts[k + 1].Start - starts[k + 1].Code : data.Length;
            if (end > starts[k].Start) units.Add(data[starts[k].Start..end]);
        }
        return units;
    }

    /// <summary>Flat grey frames through Microsoft's H.264 encoder (Baseline, no reordering); each output sample's bytes, Annex B.</summary>
    private static List<byte[]> Encode(int width, int height, int frames, byte luma)
    {
        var type = Type.GetTypeFromCLSID(MF.H264Encoder, throwOnError: true)!;
        var encoder = (IMFTransform)Activator.CreateInstance(type)!;
        try
        {
            MF.Check(MF.MFCreateMediaType(out var outType));
            outType.SetGUID(MF.MajorType, MF.MediaTypeVideo);
            outType.SetGUID(MF.SubType, MF.FormatH264);
            outType.SetUINT32(MF.AverageBitrate, 1_000_000);
            outType.SetUINT64(MF.FrameSize, MF.Pack(width, height));
            outType.SetUINT64(MF.FrameRate, MF.Pack(30, 1));
            outType.SetUINT64(MF.PixelAspectRatio, MF.Pack(1, 1));
            outType.SetUINT32(MF.InterlaceMode, 2);
            outType.SetUINT32(MF.Mpeg2Profile, 66);
            MF.Check(encoder.SetOutputType(0, outType, 0));
            MF.Check(MF.MFCreateMediaType(out var inType));
            inType.SetGUID(MF.MajorType, MF.MediaTypeVideo);
            inType.SetGUID(MF.SubType, MF.FormatNv12);
            inType.SetUINT64(MF.FrameSize, MF.Pack(width, height));
            inType.SetUINT64(MF.FrameRate, MF.Pack(30, 1));
            inType.SetUINT64(MF.PixelAspectRatio, MF.Pack(1, 1));
            inType.SetUINT32(MF.InterlaceMode, 2);
            MF.Check(encoder.SetInputType(0, inType, 0));
            encoder.ProcessMessage(MF.MessageBeginStreaming, 0);
            encoder.ProcessMessage(MF.MessageStartOfStream, 0);
            var output = new List<byte[]>();
            var size = width * height * 3 / 2;
            var picture = new byte[size];
            Array.Fill(picture, luma, 0, width * height);
            Array.Fill(picture, (byte)128, width * height, size - width * height);
            for (var i = 0; i < frames; i++)
            {
                MF.Check(MF.MFCreateMemoryBuffer((uint)size, out var buffer));
                buffer.Lock(out var pointer, out _, out _);
                Marshal.Copy(picture, 0, pointer, size);
                buffer.Unlock();
                buffer.SetCurrentLength((uint)size);
                MF.Check(MF.MFCreateSample(out var sample));
                sample.AddBuffer(buffer);
                sample.SetSampleTime(i * 333_333L);
                sample.SetSampleDuration(333_333L);
                var hr = encoder.ProcessInput(0, sample, 0);
                if (hr == MF.NotAccepting) { Pull(encoder, output); hr = encoder.ProcessInput(0, sample, 0); }
                MF.Check(hr);
                Pull(encoder, output);
            }
            encoder.ProcessMessage(MF.MessageEndOfStream, 0);
            encoder.ProcessMessage(MF.MessageDrain, 0);
            Pull(encoder, output);
            return output;
        }
        finally { Marshal.FinalReleaseComObject(encoder); }
    }

    private static void Pull(IMFTransform encoder, List<byte[]> output)
    {
        while (true)
        {
            encoder.GetOutputStreamInfo(0, out var info);
            MF.Check(MF.MFCreateMemoryBuffer(Math.Max(info.Size, 1 << 20), out var buffer));
            MF.Check(MF.MFCreateSample(out var sample));
            sample.AddBuffer(buffer);
            var data = new MftOutputDataBuffer { Sample = Marshal.GetComInterfaceForObject(sample, typeof(IMFSample)) };
            var hr = encoder.ProcessOutput(0, 1, ref data, out _);
            Marshal.Release(data.Sample);
            if (data.Events != 0) Marshal.Release(data.Events);
            if (hr == MF.NeedMoreInput) return;
            if (hr == MF.StreamChange) continue;
            MF.Check(hr);
            sample.ConvertToContiguousBuffer(out var contiguous);
            contiguous.Lock(out var pointer, out _, out var length);
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, (int)length);
            contiguous.Unlock();
            if (bytes.Length > 0) output.Add(bytes);
        }
    }
}
