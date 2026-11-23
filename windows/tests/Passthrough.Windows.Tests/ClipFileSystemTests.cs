using Passthrough.Windows.ClipSync;
using Xunit;

namespace Passthrough.Windows.Tests;

public sealed class ClipFileSystemTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "pt-clipfs-" + Guid.NewGuid().ToString("N"));

    public ClipFileSystemTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); }
        catch (IOException) { }
    }

    [Fact]
    public async Task AFileToSend_IsOpenedItself_AndOnlyAPlainFile()
    {
        var file = Path.Combine(_root, "plain.txt");
        File.WriteAllText(file, "plain");
        await using (var stream = ClipFileSystem.OpenToSend(file))
        {
            Assert.True(stream.IsAsync);
            var buffer = new byte[16];
            Assert.Equal(5, await stream.ReadAsync(buffer));
            // Others may still read, write or replace it meanwhile (the session checks its size itself).
            File.AppendAllText(file, "!");
        }
        Assert.Throws<IOException>(() => ClipFileSystem.OpenToSend(_root));
        Assert.Throws<IOException>(() => ClipFileSystem.OpenToSend(Path.Combine(_root, "missing.txt")));

        // A link swapped in for a copied file: the link is opened, not what it points at, and refused.
        var secret = Path.Combine(_root, "secret.txt");
        File.WriteAllText(secret, "not copied");
        var link = Path.Combine(_root, "link.txt");
        try { File.CreateSymbolicLink(link, secret); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // this account may not make links: nothing to check
        Assert.Throws<IOException>(() => ClipFileSystem.OpenToSend(link));
    }

    [Fact]
    public void AReceivedFile_IsMarkedAsFromAnotherComputer()
    {
        var file = Path.Combine(_root, "received.cmd");
        File.WriteAllText(file, "echo hello");
        ClipFileSystem.MarkFromAnotherComputer(file);
        // Only NTFS holds the mark; a temp folder on anything else leaves the file as it was.
        if (!string.Equals(new DriveInfo(Path.GetPathRoot(file)!).DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase)) return;
        Assert.Equal("[ZoneTransfer]\r\nZoneId=3\r\n", File.ReadAllText(file + ":Zone.Identifier"));
        Assert.Equal("echo hello", File.ReadAllText(file));
        // Never an error for a file that's gone.
        ClipFileSystem.MarkFromAnotherComputer(Path.Combine(_root, "gone", "x.txt"));
    }
}
