using System.Globalization;
using System.Numerics;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace Passthrough.Core.Transport;

/// <summary>
/// Minimal XML property list codec: dict, string, integer (long), real (double), true/false, data (byte[]), array (List of
/// object). Other elements, and integers beyond <see cref="long"/>, are left out when decoding.
/// </summary>
public static class Plist
{
    /// <summary>The deepest nesting of containers read (the root dict is level 1); usbmuxd's messages use three.</summary>
    public const int MaxDepth = 32;

    public static byte[] Encode(IDictionary<string, object> dict)
    {
        var root = new XElement("plist", new XAttribute("version", "1.0"), EncodeDict(dict));
        var doc = new XDocument(new XDeclaration("1.0", "UTF-8", null), root);
        using var ms = new MemoryStream();
        using (var w = XmlWriter.Create(ms, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false }))
            doc.Save(w);
        return ms.ToArray();
    }

    /// <summary>
    /// Reads a plist whose top value is a dict. Streams through the XML (no document tree), so a deeply nested packet
    /// is refused at <see cref="MaxDepth"/> without being built first.
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
        using var reader = XmlReader.Create(ms, settings);
        if (reader.MoveToContent() != XmlNodeType.Element || reader.IsEmptyElement) throw new FormatException("Empty plist");
        reader.Read(); // into <plist>
        while (reader.NodeType != XmlNodeType.Element)
        {
            if (reader.NodeType is XmlNodeType.EndElement or XmlNodeType.None) throw new FormatException("Empty plist");
            reader.Read();
        }
        return DecodeValue(reader, 1) as Dictionary<string, object> ?? throw new FormatException("Plist root is not a dict");
    }

    private static XElement EncodeDict(IDictionary<string, object> dict)
    {
        var e = new XElement("dict");
        foreach (var (k, v) in dict)
        {
            e.Add(new XElement("key", k));
            e.Add(EncodeValue(v));
        }
        return e;
    }

    private static XElement EncodeValue(object value) => value switch
    {
        string s => new XElement("string", s),
        bool b => new XElement(b ? "true" : "false"),
        int or long or short or byte or uint or ushort => new XElement("integer", Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)),
        byte[] d => new XElement("data", Convert.ToBase64String(d)),
        IDictionary<string, object> d => EncodeDict(d),
        IEnumerable<object> a => new XElement("array", a.Select(EncodeValue)),
        _ => throw new ArgumentException($"Unsupported plist value type {value.GetType()}"),
    };

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
            case "true": reader.Skip(); return true;
            case "false": reader.Skip(); return false;
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
                reader.Skip();
                return Skipped;
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
