using System.Text;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class PlistTests
{
    [Fact]
    public void Plist_RoundTrip()
    {
        var dict = new Dictionary<string, object>
        {
            ["s"] = "a<b>&\"c\"",
            ["n"] = 7891L,
            ["t"] = true,
            ["f"] = false,
            ["d"] = new byte[] { 0, 1, 2, 255 },
            ["a"] = new List<object> { "x", 2L, new List<object> { true }, new Dictionary<string, object> { ["k"] = "v" } },
        };

        var back = Plist.Decode(Plist.Encode(dict));

        Assert.Equal("a<b>&\"c\"", back["s"]);
        Assert.Equal(7891L, back["n"]);
        Assert.Equal(true, back["t"]);
        Assert.Equal(false, back["f"]);
        Assert.Equal(new byte[] { 0, 1, 2, 255 }, (byte[])back["d"]);
        var arr = (List<object>)back["a"];
        Assert.Equal("x", arr[0]);
        Assert.Equal(2L, arr[1]);
        Assert.Equal(true, ((List<object>)arr[2])[0]);
        Assert.Equal("v", ((Dictionary<string, object>)arr[3])["k"]);
    }

    private static Dictionary<string, object> Request(params (string Key, object Value)[] fields)
    {
        var d = new Dictionary<string, object>();
        foreach (var (k, v) in fields) d[k] = v;
        // What UsbMuxClient adds to every request, after the message's own fields (insertion order must not matter).
        d["ClientVersionString"] = "Passthrough";
        d["ProgName"] = "Passthrough";
        d["kLibUSBMuxVersion"] = 3L;
        return d;
    }

    [Fact]
    public void Plist_EncodesListenAsPropertyListSerializationDoes()
    {
        Assert.Equal(ApplePlists.Listen, Encoding.UTF8.GetString(Plist.Encode(Request(("MessageType", "Listen")))));
    }

    [Fact]
    public void Plist_EncodesConnectAsPropertyListSerializationDoes()
    {
        Assert.Equal(ApplePlists.Connect,
            Encoding.UTF8.GetString(Plist.Encode(Request(("MessageType", "Connect"), ("DeviceID", 3L), ("PortNumber", 0xD31EL)))));
    }

    [Fact]
    public void Plist_EncodesEveryTypeAsPropertyListSerializationDoes()
    {
        var dict = new Dictionary<string, object>
        {
            ["s"] = "a<b>&\"'",
            ["t"] = true,
            ["f"] = false,
            ["d"] = new byte[] { 0, 1, 255 },
            ["a"] = new List<object> { "x", 2L, new Dictionary<string, object> { ["k"] = "v" }, new List<object>(), new Dictionary<string, object>() },
            ["B"] = "upper",
            ["_u"] = "under",
            ["a2"] = "",
            ["Z"] = -5L,
            ["MessageType"] = "Connect",
            ["DeviceID"] = 3L,
            ["PortNumber"] = 0xD31EL,
        };

        Assert.Equal(ApplePlists.AllTypes, Encoding.UTF8.GetString(Plist.Encode(dict)));
    }

    [Fact]
    public void Plist_EncodesDataAndUnicodeAsPropertyListSerializationDoes()
    {
        var dict = new Dictionary<string, object>
        {
            ["z"] = Array.Empty<byte>(),
            ["n"] = new Dictionary<string, object> { ["u"] = "é→😀", ["e"] = new byte[] { 1, 2, 3 } },
            ["d"] = Enumerable.Range(0, 100).Select(i => (byte)i).ToArray(),
        };

        Assert.Equal(ApplePlists.Data, Encoding.UTF8.GetString(Plist.Encode(dict)));
    }

    [Fact]
    public void Plist_WrapsDataByIndentAsPropertyListSerializationDoes()
    {
        var data = Enumerable.Range(0, 120).Select(i => (byte)i).ToArray();
        object deep = data;
        for (var i = 0; i < 9; i++) deep = new List<object> { deep };
        var dict = new Dictionary<string, object> { ["l1"] = data, ["l2"] = new Dictionary<string, object> { ["x"] = data }, ["l11"] = deep };

        Assert.Equal(ApplePlists.DataWrap, Encoding.UTF8.GetString(Plist.Encode(dict)));
    }

    [Fact]
    public void Plist_AppleOutput_DecodesBack()
    {
        var d = Plist.Decode(Encoding.UTF8.GetBytes(ApplePlists.AllTypes));

        Assert.Equal("a<b>&\"'", d["s"]);
        Assert.Equal(new byte[] { 0, 1, 255 }, (byte[])d["d"]);
        Assert.Equal(true, d["t"]);
        Assert.Equal(-5L, d["Z"]);
        Assert.Equal(5, ((List<object>)d["a"]).Count);
        Assert.Equal(Enumerable.Range(0, 100).Select(i => (byte)i), (byte[])Plist.Decode(Encoding.UTF8.GetBytes(ApplePlists.Data))["d"]);
    }

    [Fact]
    public void Plist_DecodesUsbmuxdAttachedSample()
    {
        const string xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>DeviceID</key>
              <integer>3</integer>
              <key>MessageType</key>
              <string>Attached</string>
              <key>Properties</key>
              <dict>
                <key>ConnectionType</key>
                <string>USB</string>
                <key>ProductID</key>
                <integer>4776</integer>
                <key>SerialNumber</key>
                <string>UDID-A</string>
              </dict>
            </dict>
            </plist>
            """;

        var d = Plist.Decode(Encoding.UTF8.GetBytes(xml));

        Assert.Equal("Attached", d["MessageType"]);
        Assert.Equal(3L, d["DeviceID"]);
        var props = (Dictionary<string, object>)d["Properties"];
        Assert.Equal("UDID-A", props["SerialNumber"]);
        Assert.Equal(0x12A8L, props["ProductID"]);
    }

    [Fact]
    public void Plist_DictWithTrailingKey_Throws()
    {
        const string xml = "<plist version=\"1.0\"><dict><key>a</key><string>x</string><key>b</key></dict></plist>";

        Assert.Throws<FormatException>(() => Plist.Decode(Encoding.UTF8.GetBytes(xml)));
    }

    [Fact]
    public void Plist_UnknownElementsAndHugeIntegers_AreSkippedNotFatal()
    {
        const string xml = """
            <plist version="1.0"><dict>
              <key>MessageType</key><string>Attached</string>
              <key>When</key><date>2026-11-20T00:00:00Z</date>
              <key>Uid</key><uid>7</uid>
              <key>Huge</key><integer>18446744073709551615</integer>
              <key>List</key><array><string>a</string><date>2026-11-20T00:00:00Z</date><integer>99999999999999999999</integer><integer>2</integer></array>
              <key>DeviceID</key><integer>3</integer>
            </dict></plist>
            """;

        var d = Plist.Decode(Encoding.UTF8.GetBytes(xml));

        Assert.Equal("Attached", d["MessageType"]);
        Assert.Equal(3L, d["DeviceID"]);
        Assert.False(d.ContainsKey("When"));
        Assert.False(d.ContainsKey("Uid"));
        Assert.False(d.ContainsKey("Huge"));
        Assert.Equal(new List<object> { "a", 2L }, (List<object>)d["List"]);
    }

    [Fact]
    public void Plist_NestingBeyondTheLimit_IsRefused()
    {
        var depth = Plist.MaxDepth + 1;
        var xml = "<plist version=\"1.0\"><dict><key>a</key>" + string.Concat(Enumerable.Repeat("<array>", depth - 1)) +
                  string.Concat(Enumerable.Repeat("</array>", depth - 1)) + "</dict></plist>";

        Assert.Throws<FormatException>(() => Plist.Decode(Encoding.UTF8.GetBytes(xml)));
    }

    [Fact]
    public void Plist_NestingAtTheLimit_IsRead()
    {
        var depth = Plist.MaxDepth;
        var xml = "<plist version=\"1.0\"><dict><key>a</key>" + string.Concat(Enumerable.Repeat("<array>", depth - 1)) +
                  string.Concat(Enumerable.Repeat("</array>", depth - 1)) + "</dict></plist>";

        Assert.True(Plist.Decode(Encoding.UTF8.GetBytes(xml)).ContainsKey("a"));
    }

    /// <summary>Under usbmux's 1 MiB packet cap (less its 16-byte header), as a daemon could really send it.</summary>
    private const int MaxBody = (1 << 20) - 16 - 1;

    /// <summary>A dict holding <paramref name="depth"/> nested arrays, wrapped in <paramref name="wrapper"/> when given.</summary>
    internal static byte[] Nested(int depth, string? wrapper = null)
    {
        var inner = string.Concat(Enumerable.Repeat("<array>", depth)) + string.Concat(Enumerable.Repeat("</array>", depth));
        if (wrapper is not null) inner = $"<{wrapper}>{inner}</{wrapper}>";
        var bytes = Encoding.UTF8.GetBytes("<plist version=\"1.0\"><dict><key>a</key>" + inner + "</dict></plist>");
        Assert.True(bytes.Length <= MaxBody, $"{bytes.Length} bytes would not fit in one usbmux packet");
        return bytes;
    }

    [Fact]
    public void Plist_HugeNestingInOnePacket_IsRefusedWithoutExhaustingTheStack()
    {
        // 65,000 levels in about 975 KB: deep enough to overflow the stack of a recursive decoder.
        Assert.Throws<FormatException>(() => Plist.Decode(Nested(65_000)));
    }

    [Theory]
    [InlineData("date")]
    [InlineData("uid")]
    [InlineData("true")]
    [InlineData("false")]
    public void Plist_ContainersInsideASkippedElement_AreDepthLimitedToo(string wrapper)
    {
        Assert.Throws<FormatException>(() => Plist.Decode(Nested(40_000, wrapper)));
    }

    [Fact]
    public void Plist_SkippedElement_NestingWithinTheLimit_IsSkipped()
    {
        // The skipped element sits at level 2 (inside the root dict); its containers may go down to the limit.
        var d = Plist.Decode(Nested(Plist.MaxDepth - 2, "date"));

        Assert.Empty(d);
    }

    [Fact]
    public void Plist_SkippedElement_NestingOneBeyondTheLimit_IsRefused()
    {
        Assert.Throws<FormatException>(() => Plist.Decode(Nested(Plist.MaxDepth - 1, "date")));
    }

    [Theory]
    [InlineData("<plist version=\"1.0\"><dict/></plist><plist version=\"1.0\"><dict/></plist>")] // a second root
    [InlineData("<plist version=\"1.0\"><dict/></plist>junk")]                                     // text after the root
    [InlineData("<plist version=\"1.0\"><dict/><dict/></plist>")]                                  // a second top value
    [InlineData("<plist version=\"1.0\"><dict/><string>x</string></plist>")]
    [InlineData("<plist version=\"1.0\"><dict/>")]                                                 // no </plist>
    public void Plist_AnythingAfterTheTopDict_IsRefused(string xml)
    {
        Assert.Throws<FormatException>(() => Plist.Decode(Encoding.UTF8.GetBytes(xml)));
    }

    [Fact]
    public void Plist_WhitespaceAndCommentsAfterTheRoot_AreFine()
    {
        Assert.Empty(Plist.Decode(Encoding.UTF8.GetBytes("<plist version=\"1.0\"><dict/></plist>\n<!-- end -->\n")));
    }
}
