using Passthrough.Windows.ClipSync;
using Xunit;

namespace Passthrough.Windows.Tests;

public sealed class ClipFileSystemTests : IDisposable
{
    private readonly string _root;

    public ClipFileSystemTests()
    {
        var made = Path.Combine(Path.GetTempPath(), "pt-clipfs-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(made);
        // As files are listed: by where they truly are (the temp folder's own path may be a short name or behind a link).
        _root = ClipFileSystem.FinalPath(made);
    }

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
    public void AFolderAboveTheFile_SwappedForAJunctionSinceItWasListed_LeadsNowhere()
    {
        // Copied: a folder with one file. Elsewhere: a folder with a file of the same name that was never copied.
        var copied = Path.Combine(_root, "Copied");
        var elsewhere = Path.Combine(_root, "Elsewhere");
        Directory.CreateDirectory(copied);
        Directory.CreateDirectory(elsewhere);
        File.WriteAllText(Path.Combine(copied, "notes.txt"), "copied");
        File.WriteAllText(Path.Combine(elsewhere, "notes.txt"), "never copied");
        var (payload, failed) = Passthrough.Core.ClipSync.ClipFiles.Collect([copied], canonical: ClipFileSystem.FinalPath);
        Assert.Null(failed);
        var listed = payload!.Items.Single(i => i.Name == "Copied/notes.txt").Path!;
        using (ClipFileSystem.OpenToSend(listed)) { }

        // The folder is swapped for a junction to the other one before the file is opened.
        Directory.Move(copied, copied + "-moved");
        using var mklink = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{copied}\" \"{elsewhere}\"")
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
        })!;
        mklink.WaitForExit();
        if (mklink.ExitCode != 0) return; // no junctions here: nothing to check
        try
        {
            Assert.Equal("never copied", File.ReadAllText(listed)); // an ordinary open is led there
            Assert.Throws<IOException>(() => ClipFileSystem.OpenToSend(listed));
            // And a folder that is itself a junction is not listed at all.
            Assert.Empty(Passthrough.Core.ClipSync.ClipFiles.Collect([copied], canonical: ClipFileSystem.FinalPath).Payload!.Items);
        }
        finally { Directory.Delete(copied); } // the junction, not what it points at
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
