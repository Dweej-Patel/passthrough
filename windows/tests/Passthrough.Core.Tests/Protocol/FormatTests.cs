using Passthrough.Core.Protocol;
using Xunit;

namespace Passthrough.Core.Tests.Protocol;

public class FormatTests
{
    [Theory]
    [InlineData(0L, "0 B")]
    [InlineData(-5L, "0 B")]
    [InlineData(999L, "999 B")]
    [InlineData(1000L, "1.0 KB")]
    [InlineData(1234L, "1.2 KB")]
    [InlineData(9960L, "10 KB")]
    [InlineData(999_999L, "1.0 MB")]
    [InlineData(34_000_000L, "34 MB")]
    [InlineData(1_200_000_000L, "1.2 GB")]
    [InlineData(5_000_000_000_000L, "5.0 TB")]
    public void Bytes_TotalsIn1000BasedUnits(long bytes, string expected)
    {
        Assert.Equal(expected, Format.Bytes(bytes));
    }
}
