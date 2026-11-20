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
}
