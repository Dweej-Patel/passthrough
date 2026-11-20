using System.Text.Json;
using System.Text.RegularExpressions;

namespace Passthrough.Core.Storage;

/// <summary>
/// Settings as one JSON object in a file, rewritten whole on every change: written to <c>&lt;file&gt;.tmp</c>, flushed to
/// the disk, then renamed over the file, and the in-memory values change only once that worked. Thread-safe.
/// <para>
/// Reading is lenient: string values are kept, <c>true</c>/<c>false</c> and numbers are kept as their text, anything
/// else is skipped. A file that is not a JSON object at all is damaged: it is renamed to <c>&lt;file&gt;.bad</c> before
/// anything is written, the client id is recovered from its text when it can be (so phones still know this PC) and
/// saved at once, and <see cref="Notice"/> says what happened. If that save fails, the next launch recovers from the
/// <c>.bad</c> copy again. If the damaged file cannot be renamed, the store refuses to write over it.
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
    private readonly Action<TimeSpan> _wait;

    /// <summary>How many times <c>settings.json</c>, or its <c>.bad</c> copy, is tried when it is there but can't be read (a sharing violation is often brief).</summary>
    public const int ReadAttempts = 3;

    /// <summary>The pause between those tries.</summary>
    public static readonly TimeSpan ReadRetryDelay = TimeSpan.FromMilliseconds(200);

    /// <summary>
    /// Reads the file. Only "not found" counts as no file (an existence check can't tell a missing file from one it may
    /// not look at); a file that exists but cannot be read throws, so startup can say so, and so does a <c>.bad</c> copy
    /// that stays unreadable while the file is missing.
    /// </summary>
    /// <param name="wait">Pauses between reads of a file that is there but can't be read (default: <see cref="Thread.Sleep(TimeSpan)"/>); tests pass their own.</param>
    /// <exception cref="SettingsUnreadableException">The settings file is there but stays unreadable.</exception>
    /// <exception cref="SettingsBackupUnreadableException">The settings are missing and their <c>.bad</c> copy exists but stays unreadable.</exception>
    public JsonSettingsStore(IFileSystem files, string path, Action<TimeSpan>? wait = null)
    {
        _wait = wait ?? Thread.Sleep;
        _files = files;
        _path = path;
        _values = [];
        var bad = path + ".bad";
        if (ReadWithRetries(path, e => new SettingsUnreadableException(path, e)) is not { } text)
        {
            // No settings, but a damaged copy whose recovered values could not be saved last time: recover them again.
            if (ReadBad(bad) is { Count: > 0 } again)
            {
                _values = again;
                Notice = DamagedNotice;
                TrySave();
            }
            return;
        }
        if (Parse(text) is { } values)
        {
            _values = values;
            return;
        }

        // Damaged: keep what can be saved of it, and never write over it unless it was moved aside first.
        _values = Salvage(text);
        try
        {
            files.Move(path, bad, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _readOnly = true;
            Notice = DamagedUnsavedNotice;
            return;
        }
        Notice = _values.ContainsKey(ClientIdKey) ? DamagedNotice : DamagedLostNotice;
        // Save what was recovered now, so a restart with no change in between still has it. If that fails, the next
        // launch recovers it from the .bad copy again.
        if (_values.Count > 0) TrySave();
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
            Write(candidate);
            _values[key] = value;
        }
    }

    /// <summary>Writes <paramref name="values"/> to a durable temp file, then renames it over the settings file.</summary>
    private void Write(Dictionary<string, string> values)
    {
        if (Path.GetDirectoryName(_path) is { Length: > 0 } dir) _files.CreateDirectory(dir);
        var temp = _path + ".tmp";
        _files.WriteAllTextDurably(temp, JsonSerializer.Serialize(values));
        _files.Move(temp, _path, overwrite: true);
    }

    private void TrySave()
    {
        try { Write(_values); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } // the .bad copy is still there
    }

    /// <summary>
    /// What can be recovered from the .bad copy; nothing when there is none. One that is there but can't be read raises
    /// <see cref="SettingsBackupUnreadableException"/> after the retries, never an empty start that would give the PC a
    /// new client id.
    /// </summary>
    private Dictionary<string, string> ReadBad(string bad) =>
        ReadWithRetries(bad, e => new SettingsBackupUnreadableException(bad, e)) is { } text ? Salvage(text) : [];

    /// <summary>
    /// The file's text, or null when it is not there. Only "not found" means absent (an existence check can't tell a
    /// missing file from one it may not look at). Any other failure is tried <see cref="ReadAttempts"/> times,
    /// <see cref="ReadRetryDelay"/> apart, then becomes <paramref name="unreadable"/>'s exception.
    /// </summary>
    private string? ReadWithRetries(string file, Func<Exception, Exception> unreadable)
    {
        for (var attempt = 1; ; attempt++)
        {
            try { return _files.ReadAllText(file); }
            catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return null; }
            catch (Exception e)
            {
                if (attempt >= ReadAttempts) throw unreadable(e);
                _wait(ReadRetryDelay);
            }
        }
    }

    /// <summary>What can be kept from a damaged file: the client id, when one is in its text.</summary>
    private static Dictionary<string, string> Salvage(string text)
    {
        var values = new Dictionary<string, string>();
        if (ClientIdPattern().Match(text) is { Success: true } m) values[ClientIdKey] = m.Groups[1].Value;
        return values;
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
