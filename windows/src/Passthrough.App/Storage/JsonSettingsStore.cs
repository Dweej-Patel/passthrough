using System.Text.Json;
using Passthrough.Core.Storage;

namespace Passthrough.App.Storage;

/// <summary>Settings as one JSON object of strings in a file, rewritten whole through a temp file on every change.</summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private readonly string _path;
    private readonly object _gate = new();
    private readonly Dictionary<string, string> _values;

    public JsonSettingsStore(string path)
    {
        _path = path;
        _values = Load(path);
    }

    public string? Get(string key)
    {
        lock (_gate) return _values.GetValueOrDefault(key);
    }

    public void Set(string key, string value)
    {
        lock (_gate)
        {
            _values[key] = value;
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_values));
            File.Move(temp, _path, overwrite: true);
        }
    }

    private static Dictionary<string, string> Load(string path)
    {
        if (!File.Exists(path)) return new();
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new();
        }
        catch (JsonException)
        {
            // A damaged file starts over; the client id is made again and phones pair again.
            return new();
        }
    }
}
