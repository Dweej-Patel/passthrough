using System.Text.Json;
using System.Text.RegularExpressions;

namespace Passthrough.Core.Storage;

/// <summary>
/// Settings as one JSON object in a file, rewritten whole on every change: written to <c>&lt;file&gt;.tmp</c>, flushed to
/// the disk, then renamed over the file, and the in-memory values change only once that worked. Thread-safe.
/// <para>
/// Reading is lenient: string values are kept, <c>true</c>/<c>false</c> and numbers are kept as their text, anything
/// else is skipped. A file that is not a JSON object at all is damaged: it is renamed to <c>&lt;file&gt;.bad</c> before
/// anything is written, the client id is recovered from its text when it can be (so phones still know this PC), and
/// <see cref="Notice"/> says what happened. If the damaged file cannot be renamed, the store refuses to write over it.
/// </para>
/// </summary>
public sealed partial class JsonSettingsStore : ISettingsStore
{
    public const string DamagedNotice =
        "Passthrough's settings file was damaged and has been reset. A copy was kept as settings.json.bad.";
    public const string DamagedLostNotice =
        "Passthrough's settings file was damaged and has been reset; phones may need to pair again. A copy was kept as settings.json.bad.";
    public const string DamagedUnsavedNotice =
        "Passthrough's settings file is damaged and couldn't be moved aside, so settings won't be saved. See passthrough.log.";

    private const string ClientIdKey = "clientID";

    private readonly IFileSystem _files;
    private readonly string _path;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, string> _values;
    private readonly bool _readOnly;

    /// <summary>Reads the file. A file that exists but cannot be read throws, so startup can say so.</summary>
    public JsonSettingsStore(IFileSystem files, string path)
    {
        _files = files;
        _path = path;
        if (!files.FileExists(path))
        {
            _values = [];
            return;
        }
        var text = files.ReadAllText(path);
        if (Parse(text) is { } values)
        {
            _values = values;
            return;
        }

        // Damaged: keep what can be saved of it, and never write over it unless it was moved aside first.
        _values = [];
        if (ClientIdPattern().Match(text) is { Success: true } m) _values[ClientIdKey] = m.Groups[1].Value;
        try
        {
            files.Move(path, path + ".bad", overwrite: true);
            Notice = _values.ContainsKey(ClientIdKey) ? DamagedNotice : DamagedLostNotice;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _readOnly = true;
            Notice = DamagedUnsavedNotice;
        }
    }

    /// <summary>What to tell the user about the file (it was damaged), or null.</summary>
    public string? Notice { get; }

    public string? Get(string key)
    {
        lock (_gate) return _values.GetValueOrDefault(key);
    }

    /// <summary>Saves the value; throws, changing nothing, when the file cannot be written.</summary>
    public void Set(string key, string value)
    {
        lock (_gate)
        {
            if (_readOnly) throw new InvalidOperationException("The settings file is damaged and could not be moved aside, so it is not overwritten.");
            var candidate = new Dictionary<string, string>(_values) { [key] = value };
            if (Path.GetDirectoryName(_path) is { Length: > 0 } dir) _files.CreateDirectory(dir);
            var temp = _path + ".tmp";
            _files.WriteAllTextDurably(temp, JsonSerializer.Serialize(candidate));
            _files.Move(temp, _path, overwrite: true);
            _values[key] = value;
        }
    }

    /// <summary>The values in <paramref name="text"/>, or null when it is not a JSON object.</summary>
    private static Dictionary<string, string>? Parse(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            var values = new Dictionary<string, string>();
            foreach (var p in doc.RootElement.EnumerateObject())
            {
                switch (p.Value.ValueKind)
                {
                    case JsonValueKind.String: values[p.Name] = p.Value.GetString()!; break;
                    case JsonValueKind.True: values[p.Name] = "true"; break;
                    case JsonValueKind.False: values[p.Name] = "false"; break;
                    case JsonValueKind.Number: values[p.Name] = p.Value.GetRawText(); break;
                }
            }
            return values;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    [GeneratedRegex("\"clientID\"\\s*:\\s*\"([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\"")]
    private static partial Regex ClientIdPattern();
}
