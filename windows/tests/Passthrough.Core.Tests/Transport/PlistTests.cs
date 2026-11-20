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
}
