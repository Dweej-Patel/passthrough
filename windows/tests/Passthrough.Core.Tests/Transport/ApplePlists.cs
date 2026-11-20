namespace Passthrough.Core.Tests.Transport;

/// <summary>
/// What Apple's PropertyListSerialization (XML format) writes for these values, byte for byte: produced on a Mac with
/// a scratch Swift program calling <c>PropertyListSerialization.data(fromPropertyList:format:.xml,options:0)</c>, as
/// USBMuxClient.swift does for every usbmuxd request.
/// </summary>
internal static class ApplePlists
{
    /// <summary>USBMuxClient.swift's Listen request.</summary>
    public const string Listen =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "<dict>\n" +
        "\t<key>ClientVersionString</key>\n" +
        "\t<string>Passthrough</string>\n" +
        "\t<key>MessageType</key>\n" +
        "\t<string>Listen</string>\n" +
        "\t<key>ProgName</key>\n" +
        "\t<string>Passthrough</string>\n" +
        "\t<key>kLibUSBMuxVersion</key>\n" +
        "\t<integer>3</integer>\n" +
        "</dict>\n" +
        "</plist>\n";

    /// <summary>USBMuxClient.swift's Connect request for device 3, port 7891 (0xD31E byte-swapped).</summary>
    public const string Connect =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "<dict>\n" +
        "\t<key>ClientVersionString</key>\n" +
        "\t<string>Passthrough</string>\n" +
        "\t<key>DeviceID</key>\n" +
        "\t<integer>3</integer>\n" +
        "\t<key>MessageType</key>\n" +
        "\t<string>Connect</string>\n" +
        "\t<key>PortNumber</key>\n" +
        "\t<integer>54046</integer>\n" +
        "\t<key>ProgName</key>\n" +
        "\t<string>Passthrough</string>\n" +
        "\t<key>kLibUSBMuxVersion</key>\n" +
        "\t<integer>3</integer>\n" +
        "</dict>\n" +
        "</plist>\n";

    /// <summary>
    /// ["MessageType": "Connect", "DeviceID": 3, "PortNumber": 0xD31E, "s": "a&lt;b&gt;&amp;\"'", "t": true, "f": false,
    /// "d": Data([0, 1, 255]), "a": ["x", 2, ["k": "v"], [], [:]], "B": "upper", "_u": "under", "a2": "", "Z": -5]
    /// </summary>
    public const string AllTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "<dict>\n" +
        "\t<key>B</key>\n" +
        "\t<string>upper</string>\n" +
        "\t<key>DeviceID</key>\n" +
        "\t<integer>3</integer>\n" +
        "\t<key>MessageType</key>\n" +
        "\t<string>Connect</string>\n" +
        "\t<key>PortNumber</key>\n" +
        "\t<integer>54046</integer>\n" +
        "\t<key>Z</key>\n" +
        "\t<integer>-5</integer>\n" +
        "\t<key>_u</key>\n" +
        "\t<string>under</string>\n" +
        "\t<key>a</key>\n" +
        "\t<array>\n" +
        "\t\t<string>x</string>\n" +
        "\t\t<integer>2</integer>\n" +
        "\t\t<dict>\n" +
        "\t\t\t<key>k</key>\n" +
        "\t\t\t<string>v</string>\n" +
        "\t\t</dict>\n" +
        "\t\t<array/>\n" +
        "\t\t<dict/>\n" +
        "\t</array>\n" +
        "\t<key>a2</key>\n" +
        "\t<string></string>\n" +
        "\t<key>d</key>\n" +
        "\t<data>\n" +
        "\tAAH/\n" +
        "\t</data>\n" +
        "\t<key>f</key>\n" +
        "\t<false/>\n" +
        "\t<key>s</key>\n" +
        "\t<string>a&lt;b&gt;&amp;\"'</string>\n" +
        "\t<key>t</key>\n" +
        "\t<true/>\n" +
        "</dict>\n" +
        "</plist>\n";

    /// <summary>["d": Data(0..&lt;100), "n": ["e": Data([1, 2, 3]), "u": "é→😀"], "z": Data()]</summary>
    public const string Data =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "<dict>\n" +
        "\t<key>d</key>\n" +
        "\t<data>\n" +
        "\tAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEy\n" +
        "\tMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiYw==\n" +
        "\t</data>\n" +
        "\t<key>n</key>\n" +
        "\t<dict>\n" +
        "\t\t<key>e</key>\n" +
        "\t\t<data>\n" +
        "\t\tAQID\n" +
        "\t\t</data>\n" +
        "\t\t<key>u</key>\n" +
        "\t\t<string>é→😀</string>\n" +
        "\t</dict>\n" +
        "\t<key>z</key>\n" +
        "\t<data>\n" +
        "\t</data>\n" +
        "</dict>\n" +
        "</plist>\n";

    /// <summary>["l1": Data(0..&lt;120), "l2": ["x": Data(0..&lt;120)], "l11": that data inside nine nested arrays]</summary>
    public const string DataWrap =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "<dict>\n" +
        "\t<key>l1</key>\n" +
        "\t<data>\n" +
        "\tAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEy\n" +
        "\tMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2Rl\n" +
        "\tZmdoaWprbG1ub3BxcnN0dXZ3\n" +
        "\t</data>\n" +
        "\t<key>l11</key>\n" +
        "\t<array>\n" +
        "\t\t<array>\n" +
        "\t\t\t<array>\n" +
        "\t\t\t\t<array>\n" +
        "\t\t\t\t\t<array>\n" +
        "\t\t\t\t\t\t<array>\n" +
        "\t\t\t\t\t\t\t<array>\n" +
        "\t\t\t\t\t\t\t\t<array>\n" +
        "\t\t\t\t\t\t\t\t\t<array>\n" +
        "\t\t\t\t\t\t\t\t\t\t<data>\n" +
        "\t\t\t\t\t\t\t\tAAECAwQFBgcI\n" +
        "\t\t\t\t\t\t\t\tCQoLDA0ODxAR\n" +
        "\t\t\t\t\t\t\t\tEhMUFRYXGBka\n" +
        "\t\t\t\t\t\t\t\tGxwdHh8gISIj\n" +
        "\t\t\t\t\t\t\t\tJCUmJygpKiss\n" +
        "\t\t\t\t\t\t\t\tLS4vMDEyMzQ1\n" +
        "\t\t\t\t\t\t\t\tNjc4OTo7PD0+\n" +
        "\t\t\t\t\t\t\t\tP0BBQkNERUZH\n" +
        "\t\t\t\t\t\t\t\tSElKS0xNTk9Q\n" +
        "\t\t\t\t\t\t\t\tUVJTVFVWV1hZ\n" +
        "\t\t\t\t\t\t\t\tWltcXV5fYGFi\n" +
        "\t\t\t\t\t\t\t\tY2RlZmdoaWpr\n" +
        "\t\t\t\t\t\t\t\tbG1ub3BxcnN0\n" +
        "\t\t\t\t\t\t\t\tdXZ3\n" +
        "\t\t\t\t\t\t\t\t\t\t</data>\n" +
        "\t\t\t\t\t\t\t\t\t</array>\n" +
        "\t\t\t\t\t\t\t\t</array>\n" +
        "\t\t\t\t\t\t\t</array>\n" +
        "\t\t\t\t\t\t</array>\n" +
        "\t\t\t\t\t</array>\n" +
        "\t\t\t\t</array>\n" +
        "\t\t\t</array>\n" +
        "\t\t</array>\n" +
        "\t</array>\n" +
        "\t<key>l2</key>\n" +
        "\t<dict>\n" +
        "\t\t<key>x</key>\n" +
        "\t\t<data>\n" +
        "\t\tAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKiss\n" +
        "\t\tLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZ\n" +
        "\t\tWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3\n" +
        "\t\t</data>\n" +
        "\t</dict>\n" +
        "</dict>\n" +
        "</plist>\n";
}
