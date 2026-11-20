namespace Passthrough.Core.Storage;

/// <summary>An <see cref="ISecretStore"/> that forgets everything when the process ends. Thread-safe.</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Lock _gate = new();
    private readonly Dictionary<string, string> _values = [];

    public string? Get(string slot)
    {
        lock (_gate) return _values.GetValueOrDefault(slot);
    }

    public void Set(string slot, string value)
    {
        lock (_gate) _values[slot] = value;
    }

    public void Delete(string slot)
    {
        lock (_gate) _values.Remove(slot);
    }

    public IReadOnlyList<string> Slots()
    {
        lock (_gate) return [.. _values.Keys.Order(StringComparer.Ordinal)];
    }
}
