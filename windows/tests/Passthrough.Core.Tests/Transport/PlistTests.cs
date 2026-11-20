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

    [Fact]
    public void Plist_EncodesExactlyThisXml()
    {
        // Pinned bytes: a change in what the encoder emits (declaration, escaping, element names, order) shows here.
        var dict = new Dictionary<string, object>
        {
            ["MessageType"] = "Connect",
            ["DeviceID"] = 3L,
            ["PortNumber"] = 0xD31EL,
            ["s"] = "a<b>&",
            ["t"] = true,
            ["f"] = false,
            ["d"] = new byte[] { 0, 1, 255 },
            ["a"] = new List<object> { "x", 2L },
        };

        Assert.Equal(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            "<key>DeviceID</key><integer>3</integer>" +
            "<key>PortNumber</key><integer>54046</integer>" +
            "<key>s</key><string>a&lt;b&gt;&amp;</string>" +
            "<key>t</key><true /><key>f</key><false />" +
            "<key>d</key><data>AAH/</data>" +
            "<key>a</key><array><string>x</string><integer>2</integer></array>" +
            "</dict></plist>",
            Encoding.UTF8.GetString(Plist.Encode(dict)));
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

    [Fact]
    public void Plist_HugeNestingInOnePacket_IsRefusedWithoutExhaustingTheStack()
    {
        // About 900 KB, under usbmux's 1 MB packet cap: deep enough to overflow the stack of a recursive decoder.
        const int depth = 100_000;
        var xml = "<plist version=\"1.0\"><dict><key>a</key>" + string.Concat(Enumerable.Repeat("<array>", depth)) +
                  string.Concat(Enumerable.Repeat("</array>", depth)) + "</dict></plist>";

        Assert.Throws<FormatException>(() => Plist.Decode(Encoding.UTF8.GetBytes(xml)));
    }
}
