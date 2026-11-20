using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace Passthrough.Core.Transport;

/// <summary>Minimal XML property list codec: dict, string, integer (long), true/false, data (byte[]), array (List of object).</summary>
public static class Plist
{
    public static byte[] Encode(IDictionary<string, object> dict)
    {
        var root = new XElement("plist", new XAttribute("version", "1.0"), EncodeDict(dict));
        var doc = new XDocument(new XDeclaration("1.0", "UTF-8", null), root);
        using var ms = new MemoryStream();
        using (var w = XmlWriter.Create(ms, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false }))
            doc.Save(w);
        return ms.ToArray();
    }

    public static Dictionary<string, object> Decode(ReadOnlySpan<byte> xml)
    {
        using var ms = new MemoryStream(xml.ToArray());
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
        using var reader = XmlReader.Create(ms, settings);
        var doc = XDocument.Load(reader);
        var top = doc.Root?.Elements().FirstOrDefault() ?? throw new FormatException("Empty plist");
        return DecodeValue(top) as Dictionary<string, object> ?? throw new FormatException("Plist root is not a dict");
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

    private static object DecodeValue(XElement e) => e.Name.LocalName switch
    {
        "string" => e.Value,
        "integer" => long.Parse(e.Value.Trim(), CultureInfo.InvariantCulture),
        "real" => double.Parse(e.Value.Trim(), CultureInfo.InvariantCulture),
        "true" => true,
        "false" => false,
        "data" => Convert.FromBase64String(e.Value),
        "array" => e.Elements().Select(DecodeValue).ToList(),
        "dict" => DecodeDict(e),
        var other => throw new FormatException($"Unsupported plist element <{other}>"),
    };

    private static Dictionary<string, object> DecodeDict(XElement e)
    {
        var result = new Dictionary<string, object>();
        var children = e.Elements().ToList();
        for (var i = 0; i + 1 < children.Count; i += 2)
        {
            if (children[i].Name.LocalName != "key") throw new FormatException("Expected <key> in dict");
            result[children[i].Value] = DecodeValue(children[i + 1]);
        }
        return result;
    }
}
