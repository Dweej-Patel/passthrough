using System.Text;
using Passthrough.Core.Shell.Sessions;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

public class ConPtyOutputFilterTests
{
    private static string Run(ConPtyOutputFilter filter, params string[] chunks) =>
        string.Concat(chunks.Select(c => Encoding.UTF8.GetString(filter.Filter(Encoding.UTF8.GetBytes(c))))) + Encoding.UTF8.GetString(filter.Flush());

    [Fact]
    public void ThePseudoconsolesOpeningIsDropped()
    {
        Assert.Equal("PS C:\\> ", Run(new(), "\u001b[1t\u001b[c\u001b[?1004h\u001b[?9001hPS C:\\> "));
    }

    [Fact]
    public void ItIsDroppedEvenSplitAcrossReads()
    {
        var filter = new ConPtyOutputFilter();
        Assert.Equal("", Encoding.UTF8.GetString(filter.Filter("\u001b[1t\u001b"u8)));
        Assert.Equal("", Encoding.UTF8.GetString(filter.Filter("[c\u001b[?10"u8)));
        Assert.Equal("hi", Run(filter, "04h\u001b[?9001h", "hi"));
    }

    [Fact]
    public void AProgramsOwnFocusReportsAndDeviceRequestsPassOnceSomethingElseCame()
    {
        Assert.Equal("$ \u001b[?1004h\u001b[c", Run(new(), "\u001b[?9001h$ ", "\u001b[?1004h\u001b[c"));
    }

    [Fact]
    public void Win32InputModeIsDroppedAnywhere()
    {
        Assert.Equal("ab\u001b[?1004l", Run(new(), "a", "\u001b[?9001hb\u001b[?1004l\u001b[?9", "001l"));
    }

    [Fact]
    public void OtherSequencesAndACutOffEndPass()
    {
        Assert.Equal("x\u001b[?1049h\u001b[31m\u001b[?90", Run(new(), "x\u001b[?1049h\u001b[31m", "\u001b[?90"));
        Assert.Equal("\u001b[?2004h", Run(new(), "\u001b[?2004h"));
    }
}
