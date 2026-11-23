using System.Globalization;
using System.Text;

namespace Passthrough.Core.ClipSync;

/// <summary>
/// Windows keeps HTML on the clipboard as "HTML Format" (CF_HTML): a header of byte offsets, then the page with the
/// copied part between two comments. The wire carries plain HTML, so a Windows side strips the header going out and
/// adds it coming in.
/// </summary>
public static class ClipHtml
{
    private const string StartMark = "<!--StartFragment-->", EndMark = "<!--EndFragment-->";

    /// <summary>The plain HTML (UTF-8) inside a CF_HTML block; null when the header can't be read.</summary>
    public static byte[]? FromClipboard(ReadOnlySpan<byte> block)
    {
        // The header is ASCII, and short.
        var head = Encoding.ASCII.GetString(block[..Math.Min(block.Length, 512)]);
        var (start, end) = (Offset(head, "StartHTML:"), Offset(head, "EndHTML:"));
        if (start is null or < 0 || end is null) (start, end) = (Offset(head, "StartFragment:"), Offset(head, "EndFragment:"));
        if (start is not { } from || end is not { } to || from < 0 || to > block.Length || from >= to) return null;
        return block[from..to].ToArray();
    }

    private static int? Offset(string head, string key)
    {
        var at = head.IndexOf(key, StringComparison.OrdinalIgnoreCase);
        if (at < 0) return null;
        var digits = at + key.Length;
        var stop = digits;
        while (stop < head.Length && (char.IsAsciiDigit(head[stop]) || head[stop] == '-' && stop == digits)) stop++;
        return int.TryParse(head.AsSpan(digits, stop - digits), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    /// <summary>A CF_HTML block (with its ending NUL) for plain HTML in UTF-8: a whole page, or just a piece of one.</summary>
    public static byte[] ToClipboard(ReadOnlySpan<byte> html)
    {
        var text = Encoding.UTF8.GetString(html);
        if (!text.Contains(StartMark, StringComparison.Ordinal) || !text.Contains(EndMark, StringComparison.Ordinal))
        {
            var body = text.IndexOf("<body", StringComparison.OrdinalIgnoreCase);
            var open = body >= 0 ? text.IndexOf('>', body) : -1;
            var close = open >= 0 ? text.LastIndexOf("</body", StringComparison.OrdinalIgnoreCase) : -1;
            text = open >= 0 && close > open
                ? text[..(open + 1)] + StartMark + text[(open + 1)..close] + EndMark + text[close..]
                : "<html><body>" + StartMark + text + EndMark + "</body></html>";
        }
        const string format = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        var headerLength = string.Format(CultureInfo.InvariantCulture, format, 0, 0, 0, 0).Length;
        var page = Encoding.UTF8.GetBytes(text);
        var fragmentStart = Encoding.UTF8.GetByteCount(text.AsSpan(0, text.IndexOf(StartMark, StringComparison.Ordinal) + StartMark.Length));
        var fragmentEnd = Encoding.UTF8.GetByteCount(text.AsSpan(0, text.LastIndexOf(EndMark, StringComparison.Ordinal)));
        var header = Encoding.ASCII.GetBytes(string.Format(CultureInfo.InvariantCulture, format,
            headerLength, headerLength + page.Length, headerLength + fragmentStart, headerLength + fragmentEnd));
        var block = new byte[header.Length + page.Length + 1];
        header.CopyTo(block, 0);
        page.CopyTo(block, header.Length);
        return block;
    }
}
