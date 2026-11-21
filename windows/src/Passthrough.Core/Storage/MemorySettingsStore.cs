namespace Passthrough.Core.Storage;

/// <summary>An <see cref="ISettingsStore"/> that forgets everything when the process ends. Thread-safe.</summary>
public sealed class MemorySettingsStore : ISettingsStore
{
    private readonly Lock _gate = new();
    private readonly Dictionary<string, string> _values = [];

    public string? Get(string key)
    {
        lock (_gate) return _values.GetValueOrDefault(key);
    }

    public void Set(string key, string value)
    {
        lock (_gate) _values[key] = value;
    }
}
