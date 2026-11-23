using System.Text;
using Passthrough.Core.ClipSync;
using Xunit;

namespace Passthrough.Core.Tests.ClipSync;

public class ClipHtmlTests
{
    private static string Header(string block, string key) => block[(block.IndexOf(key, StringComparison.Ordinal) + key.Length)..].Split('\r')[0];

    [Theory]
    [InlineData("<b>héllo</b> wörld")]
    [InlineData("<html><head><meta charset=\"utf-8\"></head><body class=\"x\"><p>日本語</p></body></html>")]
    [InlineData("<html><body><!--StartFragment--><i>kept</i><!--EndFragment--></body></html>")]
    public void ToClipboard_PointsItsOffsetsAtThePageAndTheCopiedPart_AndComesBackAsThePage(string html)
    {
        var block = ClipHtml.ToClipboard(Encoding.UTF8.GetBytes(html));
        Assert.Equal(0, block[^1]);
        var text = Encoding.UTF8.GetString(block);
        Assert.StartsWith("Version:0.9\r\nStartHTML:", text);
        int startHtml = int.Parse(Header(text, "StartHTML:")), endHtml = int.Parse(Header(text, "EndHTML:"));
        int startFragment = int.Parse(Header(text, "StartFragment:")), endFragment = int.Parse(Header(text, "EndFragment:"));
        Assert.Equal(block.Length - 1, endHtml);
        var page = Encoding.UTF8.GetString(block[startHtml..endHtml]);
        Assert.StartsWith("<html>", page);
        var fragment = Encoding.UTF8.GetString(block[startFragment..endFragment]);
        // The copied part sits exactly between the two comments.
        Assert.Equal("<!--StartFragment-->", Encoding.UTF8.GetString(block[(startFragment - 20)..startFragment]));
        Assert.Equal("<!--EndFragment-->", Encoding.UTF8.GetString(block[endFragment..(endFragment + 18)]));
        Assert.DoesNotContain("<!--", fragment);
        Assert.Equal(page, Encoding.UTF8.GetString(ClipHtml.FromClipboard(block)!));
    }

    [Fact]
    public void FromClipboard_ReadsWhatBrowsersWrite_AndRefusesANonsenseHeader()
    {
        const string page = "<html>\r\n<body>\r\n<!--StartFragment--><a href=\"https://example.com\">link</a><!--EndFragment-->\r\n</body>\r\n</html>";
        var header = "Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:{0:D10}\r\nStartFragment:0000000141\r\nEndFragment:0000000182\r\nSourceURL:x\r\n";
        header = string.Format(header, 0);
        var start = header.Length;
        var block = Encoding.UTF8.GetBytes(header.Replace("StartHTML:0000000105", $"StartHTML:{start:D10}").Replace("EndHTML:0000000000", $"EndHTML:{start + Encoding.UTF8.GetByteCount(page):D10}") + page);
        Assert.Equal(page, Encoding.UTF8.GetString(ClipHtml.FromClipboard(block)!));
        // StartHTML -1 (no context): the fragment's offsets are used.
        var fragmentOnly = Encoding.UTF8.GetBytes("Version:1.0\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:0000000100\r\nEndFragment:0000000105\r\n".PadRight(100) + "hello");
        Assert.Equal("hello", Encoding.UTF8.GetString(ClipHtml.FromClipboard(fragmentOnly)!));
        Assert.Null(ClipHtml.FromClipboard("just some text"u8));
        Assert.Null(ClipHtml.FromClipboard("StartHTML:0000000900\r\nEndHTML:0000000950\r\n"u8));
        Assert.Null(ClipHtml.FromClipboard("StartHTML:0000000030\r\nEndHTML:0000000010\r\n................"u8));
        Assert.Null(ClipHtml.FromClipboard([]));
    }
}
