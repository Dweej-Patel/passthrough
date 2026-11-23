using System.Text.Json;

namespace Passthrough.Core.Tests;

public static class Fixtures
{
    private static readonly Lazy<JsonElement> Loaded = new(() =>
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures.json");
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        return doc.RootElement.Clone();
    });

    public static JsonElement Root => Loaded.Value;

    /// <summary>
    /// Whether two JSON texts hold the same value: objects by their members in any order, arrays in
    /// order, numbers by value (<c>1758066000.0</c> equals <c>1758066000</c>), as the Kotlin suite's
    /// <c>normalize</c> and Swift's <c>NSDictionary</c> compare them.
    /// </summary>
    public static bool JsonEqual(string a, string b)
    {
        using var x = JsonDocument.Parse(a);
        using var y = JsonDocument.Parse(b);
        return Same(x.RootElement, y.RootElement);
    }

    private static bool Same(JsonElement a, JsonElement b)
    {
        if (a.ValueKind != b.ValueKind) return false;
        switch (a.ValueKind)
        {
            case JsonValueKind.Object:
                var left = a.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                var right = b.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
                return left.Count == right.Count && left.All(p => right.TryGetValue(p.Key, out var v) && Same(p.Value, v));
            case JsonValueKind.Array:
                var l = a.EnumerateArray().ToList();
                var r = b.EnumerateArray().ToList();
                return l.Count == r.Count && l.Zip(r).All(pair => Same(pair.First, pair.Second));
            case JsonValueKind.Number:
                return a.GetDecimal() == b.GetDecimal();
            case JsonValueKind.String:
                return a.GetString() == b.GetString();
            default:
                return true;
        }
    }
}
