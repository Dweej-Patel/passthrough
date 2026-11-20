using System.Globalization;
using System.Numerics;
using System.Text;
using System.Xml;

namespace Passthrough.Core.Transport;

/// <summary>
/// Minimal XML property list codec: dict, string, integer (long), real (double, decode only), true/false, data
/// (byte[]), array (List of object). Encodes byte for byte as Apple's PropertyListSerialization does in XML format
/// (what USBMuxClient.swift and Apple's own usbmuxd clients send). Other elements, and integers beyond
/// <see cref="long"/>, are left out when decoding.
/// </summary>
public static class Plist
{
    /// <summary>The deepest nesting of containers read (the root dict is level 1); usbmuxd's messages use three.</summary>
    public const int MaxDepth = 32;

    private const string Header =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n";

    /// <summary>
    /// CoreFoundation's XML layout: one element per line, indented with tabs; dict keys in ordinal (UTF-16) order;
    /// empty containers as <c>&lt;array/&gt;</c>; only <c>&amp;</c>, <c>&lt;</c> and <c>&gt;</c> escaped; data as
    /// base64 lines indented with at most eight tabs, each line 76 − 8 × tabs characters.
    /// </summary>
    public static byte[] Encode(IDictionary<string, object> dict)
    {
        var sb = new StringBuilder(Header);
        AppendValue(sb, dict, 0);
        sb.Append("</plist>\n");
        return new UTF8Encoding(false).GetBytes(sb.ToString());
    }

    private static void AppendValue(StringBuilder sb, object value, int indent)
    {
        sb.Append('\t', indent);
        switch (value)
        {
            case string s:
                sb.Append("<string>").Append(Escape(s)).Append("</string>\n");
                break;
            case bool b:
                sb.Append(b ? "<true/>\n" : "<false/>\n");
                break;
            case int or long or short or byte or uint or ushort:
                sb.Append("<integer>").Append(Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)).Append("</integer>\n");
                break;
            case byte[] d:
                sb.Append("<data>\n");
                var tabs = Math.Min(indent, 8);
                var width = 76 - 8 * tabs;
                var text = Convert.ToBase64String(d);
                for (var i = 0; i < text.Length; i += width)
                    sb.Append('\t', tabs).Append(text, i, Math.Min(width, text.Length - i)).Append('\n');
                sb.Append('\t', indent).Append("</data>\n");
                break;
            case IDictionary<string, object> d:
                if (d.Count == 0)
                {
                    sb.Append("<dict/>\n");
                    break;
                }
                sb.Append("<dict>\n");
                foreach (var key in d.Keys.Order(StringComparer.Ordinal))
                {
                    sb.Append('\t', indent + 1).Append("<key>").Append(Escape(key)).Append("</key>\n");
                    AppendValue(sb, d[key], indent + 1);
                }
                sb.Append('\t', indent).Append("</dict>\n");
                break;
            case IEnumerable<object> a:
                var items = a.ToList();
                if (items.Count == 0)
                {
                    sb.Append("<array/>\n");
                    break;
                }
                sb.Append("<array>\n");
                foreach (var item in items) AppendValue(sb, item, indent + 1);
                sb.Append('\t', indent).Append("</array>\n");
                break;
            default:
                throw new ArgumentException($"Unsupported plist value type {value.GetType()}");
        }
    }

    private static string Escape(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    /// <summary>
    /// Reads a plist whose top value is a dict, and nothing after it. Streams through the XML (no document tree), so a
    /// deeply nested packet is refused at <see cref="MaxDepth"/> without being built first. Anything malformed is a
    /// <see cref="FormatException"/>.
    /// </summary>
    public static Dictionary<string, object> Decode(ReadOnlySpan<byte> xml)
    {
        using var ms = new MemoryStream(xml.ToArray());
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            IgnoreWhitespace = true,
        };
        try
        {
            using var reader = XmlReader.Create(ms, settings);
            if (reader.MoveToContent() != XmlNodeType.Element || reader.IsEmptyElement) throw new FormatException("Empty plist");
            reader.Read(); // into <plist>
            while (reader.NodeType != XmlNodeType.Element)
            {
                if (reader.NodeType is XmlNodeType.EndElement or XmlNodeType.None) throw new FormatException("Empty plist");
                reader.Read();
            }
            var top = DecodeValue(reader, 1) as Dictionary<string, object> ?? throw new FormatException("Plist root is not a dict");
            // Then the root's end tag, and the end of the input: no second value, no second root, no trailing text.
            while (reader.NodeType is not (XmlNodeType.EndElement or XmlNodeType.Element or XmlNodeType.None)) reader.Read();
            if (reader.NodeType != XmlNodeType.EndElement) throw new FormatException("Plist has more than one top value");
            while (reader.Read())
            {
                if (reader.NodeType is not (XmlNodeType.Whitespace or XmlNodeType.Comment or XmlNodeType.ProcessingInstruction))
                    throw new FormatException("Plist has something after its end");
            }
            return top;
        }
        catch (XmlException e)
        {
            throw new FormatException("Plist is not well-formed XML", e);
        }
    }

    /// <summary>
    /// One value, from its start tag to just past its end tag; <see cref="Skipped"/> for an element this codec does not
    /// read (<c>date</c>, <c>uid</c>, ...) or an integer outside <see cref="long"/>, so one odd field never makes a whole
    /// message unreadable. Containers deeper than <see cref="MaxDepth"/> are refused, which also bounds the recursion.
    /// </summary>
    private static object DecodeValue(XmlReader reader, int depth)
    {
        switch (reader.LocalName)
        {
            case "string": return reader.ReadElementContentAsString();
            case "integer": return DecodeInteger(reader.ReadElementContentAsString().Trim());
            case "real": return double.Parse(reader.ReadElementContentAsString().Trim(), CultureInfo.InvariantCulture);
            case "true": SkipElement(reader, depth); return true;
            case "false": SkipElement(reader, depth); return false;
            case "data": return Convert.FromBase64String(reader.ReadElementContentAsString());
            case "array":
                CheckDepth(depth);
                var list = new List<object>();
                foreach (var _ in Children(reader))
                {
                    var item = DecodeValue(reader, depth + 1);
                    if (item != Skipped) list.Add(item);
                }
                return list;
            case "dict":
                CheckDepth(depth);
                var dict = new Dictionary<string, object>();
                string? key = null;
                foreach (var _ in Children(reader))
                {
                    if (key is null)
                    {
                        if (reader.LocalName != "key") throw new FormatException("Expected <key> in dict");
                        key = reader.ReadElementContentAsString();
                        continue;
                    }
                    var value = DecodeValue(reader, depth + 1);
                    if (value != Skipped) dict[key] = value;
                    key = null;
                }
                if (key is not null) throw new FormatException("Dict has a key without a value");
                return dict;
            default:
                SkipElement(reader, depth);
                return Skipped;
        }
    }

    /// <summary>
    /// Moves past an element this codec does not read, from its start tag to just past its end tag, without recursion.
    /// Nothing nested in it may sit deeper than <see cref="MaxDepth"/>, the limit a container read here obeys (the
    /// skipped element is at <paramref name="depth"/>, its children one deeper).
    /// </summary>
    private static void SkipElement(XmlReader reader, int depth)
    {
        if (reader.IsEmptyElement)
        {
            reader.Read();
            return;
        }
        reader.Read();
        var level = 1; // the level, below the skipped element, of the node the reader is on
        while (true)
        {
            switch (reader.NodeType)
            {
                case XmlNodeType.Element:
                    CheckDepth(depth + level);
                    if (!reader.IsEmptyElement) level++;
                    break;
                case XmlNodeType.EndElement:
                    if (--level == 0)
                    {
                        reader.Read();
                        return;
                    }
                    break;
                case XmlNodeType.None:
                    throw new FormatException("Plist ends inside an element");
            }
            reader.Read();
        }
    }

    /// <summary>
    /// Steps through a container's child elements, leaving the reader on each child's start tag (the caller consumes
    /// the child), and ends just past the container's end tag. Text between children is ignored.
    /// </summary>
    private static IEnumerable<bool> Children(XmlReader reader)
    {
        if (reader.IsEmptyElement)
        {
            reader.Read();
            yield break;
        }
        reader.Read();
        while (reader.NodeType != XmlNodeType.EndElement)
        {
            if (reader.NodeType == XmlNodeType.None) throw new FormatException("Plist ends inside a container");
            if (reader.NodeType == XmlNodeType.Element) yield return true;
            else reader.Read();
        }
        reader.Read();
    }

    private static object DecodeInteger(string text)
    {
        if (long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n)) return n;
        if (BigInteger.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _)) return Skipped; // a valid integer, just too big
        throw new FormatException("Plist integer is not a number");
    }

    private static void CheckDepth(int depth)
    {
        if (depth > MaxDepth) throw new FormatException($"Plist nests deeper than {MaxDepth} levels");
    }

    /// <summary>Marks a value left out of the decoded result.</summary>
    private static readonly object Skipped = new();
}
