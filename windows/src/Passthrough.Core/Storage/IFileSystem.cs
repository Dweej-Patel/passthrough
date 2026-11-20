namespace Passthrough.Core.Storage;

/// <summary>The few file operations the settings store and the log need, so their strategies are testable without a disk.</summary>
public interface IFileSystem
{
    bool FileExists(string path);

    string ReadAllText(string path);

    /// <summary>Writes the whole file and flushes it to the disk before returning.</summary>
    void WriteAllTextDurably(string path, string text);

    void AppendAllText(string path, string text);

    /// <summary>The file's size in bytes; 0 when it does not exist.</summary>
    long FileLength(string path);

    /// <summary>Renames a file, replacing <paramref name="to"/> when <paramref name="overwrite"/> is set.</summary>
    void Move(string from, string to, bool overwrite);

    void CreateDirectory(string path);
}
