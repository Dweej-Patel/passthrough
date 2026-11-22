using Passthrough.Core.Screen;
using Xunit;

namespace Passthrough.Core.Tests.Screen;

public sealed class H264SpsTests
{
    [Theory]
    [InlineData(1728, 1116, 100)]
    [InlineData(1920, 1080, 100)]
    [InlineData(3024, 1964, 100)]
    [InlineData(4096, 4096, 100)]
    [InlineData(16, 16, 66)]
    [InlineData(1366, 768, 77)]
    public void ReadsTheCroppedSize(int width, int height, int profile)
    {
        var sps = H264Sps.TryParse(SpsBuilder.Sps(width, height, profile));
        Assert.NotNull(sps);
        Assert.Equal((width, height, profile), (sps.Width, sps.Height, sps.Profile));
        Assert.True(sps.IsAcceptable);
        Assert.Null(sps.FullRange);
    }

    [Fact]
    public void ReadsTheVideoSignal()
    {
        var sps = H264Sps.TryParse(SpsBuilder.Sps(1280, 720, fullRange: false, matrix: 1))!;
        Assert.Equal((false, 1), (sps.FullRange, sps.Matrix));
        Assert.True(H264Sps.TryParse(SpsBuilder.Sps(1280, 720, fullRange: true))!.FullRange);
    }

    [Fact]
    public void SkipsAScalingMatrixAndOtherPictureOrders()
    {
        Assert.Equal(720, H264Sps.TryParse(SpsBuilder.Sps(1280, 720, scalingMatrix: true))?.Height);
        Assert.Equal(720, H264Sps.TryParse(SpsBuilder.Sps(1280, 720, pocType: 2))?.Height);
    }

    [Fact]
    public void RefusesWhatADecoderHereIsNotGiven()
    {
        Assert.False(H264Sps.TryParse(SpsBuilder.Sps(1280, 720, profile: 110))!.IsAcceptable, "High 10");
        Assert.False(H264Sps.TryParse(SpsBuilder.Sps(1280, 720, chroma: 2))!.IsAcceptable, "4:2:2");
        Assert.False(H264Sps.TryParse(SpsBuilder.Sps(1280, 720, bitDepth: 10))!.IsAcceptable, "10 bits");
        Assert.False(H264Sps.TryParse(SpsBuilder.Sps(1280, 720, frameOnly: false))!.IsAcceptable, "fields");
        var sps = SpsBuilder.Sps(1280, 720);
        Assert.Null(H264Sps.TryParse([0x68, .. sps[1..]])); // not an SPS
        Assert.Null(H264Sps.TryParse(sps[..6]));             // cut short
        Assert.Null(H264Sps.TryParse([]));
    }

    [Fact]
    public void EmulationPreventionIsRemovedFirst()
    {
        Assert.Equal([0, 0, 1, 0, 0, 0, 0, 3], H264Sps.Unescape([0, 0, 3, 1, 0, 0, 3, 0, 0, 3, 3]));
    }

    /// <summary>Random bytes after an SPS header never throw: they parse to something or to nothing.</summary>
    [Fact]
    public void RandomBytesNeverThrow()
    {
        var random = new Random(4);
        for (var i = 0; i < 20_000; i++)
        {
            var bytes = new byte[random.Next(1, 40)];
            random.NextBytes(bytes);
            bytes[0] = 0x67;
            if (H264Sps.TryParse(bytes) is { } sps) Assert.True(sps.Width > 0 && sps.Height > 0 && sps.Width <= 1024 * 16);
        }
    }
}

public sealed class AnnexBTests
{
    private static readonly byte[] Sps = [0x67, 1, 2], Pps = [0x68, 3];

    private static byte[] Avcc(params byte[][] units) =>
        [.. units.SelectMany(u => new byte[] { (byte)(u.Length >> 24), (byte)(u.Length >> 16), (byte)(u.Length >> 8), (byte)u.Length }.Concat(u))];

    [Fact]
    public void LengthsBecomeStartCodesAndInBandSetsAreReplacedByTheCheckedOnes()
    {
        var frame = Avcc([0x67, 9, 9, 9], [0x68, 9], [0x06, 5], [0x65, 1, 2, 3]);
        using var key = AnnexB.Convert(frame, ScreenCodec.H264, keyframe: true, [Sps, Pps])!;
        Assert.Equal([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x06, 5, 0, 0, 0, 1, 0x65, 1, 2, 3], key.Memory.ToArray());
        using var delta = AnnexB.Convert(Avcc([0x41, 7]), ScreenCodec.H264, keyframe: false, [Sps, Pps])!;
        Assert.Equal([0, 0, 0, 1, 0x41, 7], delta.Memory.ToArray());
    }

    [Fact]
    public void HevcSetsAreDroppedByTheirType()
    {
        // VPS 32, SPS 33, PPS 34 (type in bits 1-6 of the first header byte), then an IDR slice (19).
        var frame = Avcc([0x40, 1, 9], [0x42, 1, 9], [0x44, 1, 9], [0x26, 1, 5]);
        using var out1 = AnnexB.Convert(frame, ScreenCodec.Hevc, keyframe: false, [])!;
        Assert.Equal([0, 0, 0, 1, 0x26, 1, 5], out1.Memory.ToArray());
    }

    [Fact]
    public void BrokenFramesAreMalformed()
    {
        Assert.Throws<MalformedStreamException>(() => AnnexB.Convert([], ScreenCodec.H264, false, []));
        Assert.Throws<MalformedStreamException>(() => AnnexB.Convert([0, 0, 0, 0], ScreenCodec.H264, false, []));            // a zero length
        Assert.Throws<MalformedStreamException>(() => AnnexB.Convert([0, 0, 0, 5, 0x41], ScreenCodec.H264, false, []));      // past the end
        Assert.Throws<MalformedStreamException>(() => AnnexB.Convert([0, 0, 0, 1, 0x41, 0, 0], ScreenCodec.H264, false, [])); // a torn length
        var many = Avcc([.. Enumerable.Repeat(new byte[] { 0x41 }, AnnexB.MaxUnits + 1)]);
        Assert.Throws<MalformedStreamException>(() => AnnexB.Convert(many, ScreenCodec.H264, false, []));
        AnnexB.Convert(Avcc([.. Enumerable.Repeat(new byte[] { 0x41 }, AnnexB.MaxUnits)]), ScreenCodec.H264, false, [])!.Dispose();
    }

    [Fact]
    public void AFrameOfParameterSetsOnlyLeavesNothingToDecode() =>
        Assert.Null(AnnexB.Convert(Avcc([0x67, 1], [0x68, 2]), ScreenCodec.H264, keyframe: true, [Sps, Pps]));
}
