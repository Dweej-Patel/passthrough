using System.Text;

namespace Passthrough.Core.Storage;

/// <summary>The real disk, through <see cref="System.IO"/>.</summary>
public sealed class PhysicalFileSystem : IFileSystem
{
    public static PhysicalFileSystem Instance { get; } = new();

    public bool FileExists(string path) => File.Exists(path);

    public string ReadAllText(string path) => File.ReadAllText(path);

    public void WriteAllTextDurably(string path, string text)
    {
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(text);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
    }

    public void AppendAllText(string path, string text) => File.AppendAllText(path, text);

    public long FileLength(string path)
    {
        var info = new FileInfo(path);
        return info.Exists ? info.Length : 0;
    }

    public void Move(string from, string to, bool overwrite) => File.Move(from, to, overwrite);

    public void CreateDirectory(string path) => Directory.CreateDirectory(path);
}
