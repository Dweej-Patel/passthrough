using System.Collections.Concurrent;
using Passthrough.Core.Storage;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// Files in a dictionary, with a log of the operations that change them and a hook to make any operation fail
/// (<see cref="Fail"/>: return an exception to throw for that operation and path, or null).
/// </summary>
public sealed class MemoryFileSystem : IFileSystem
{
    public readonly ConcurrentDictionary<string, string> Files = new();
    public readonly ConcurrentQueue<string> Operations = new();
    public Func<string, string, Exception?> Fail = (_, _) => null;

    public bool FileExists(string path) => Files.ContainsKey(path);

    public string ReadAllText(string path)
    {
        Check("read", path);
        return Files.TryGetValue(path, out var text) ? text : throw new FileNotFoundException(path);
    }

    public void WriteAllTextDurably(string path, string text)
    {
        Check("write", path);
        Operations.Enqueue($"write {path}");
        Files[path] = text;
    }

    public void AppendAllText(string path, string text)
    {
        Check("append", path);
        Files.AddOrUpdate(path, text, (_, old) => old + text);
    }

    public long FileLength(string path) => Files.TryGetValue(path, out var text) ? System.Text.Encoding.UTF8.GetByteCount(text) : 0;

    public void Move(string from, string to, bool overwrite)
    {
        Check("move", from);
        if (!Files.TryGetValue(from, out var text)) throw new FileNotFoundException(from);
        if (!overwrite && Files.ContainsKey(to)) throw new IOException($"{to} exists");
        Operations.Enqueue($"move {from} {to}");
        Files[to] = text;
        Files.TryRemove(from, out _);
    }

    public void CreateDirectory(string path) => Check("mkdir", path);

    private void Check(string op, string path)
    {
        if (Fail(op, path) is { } e) throw e;
    }
}
