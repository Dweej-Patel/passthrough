using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Passthrough.Core.ClipSync;

namespace Passthrough.Windows.ClipSync;

/// <summary>What clipboard sync asks of Windows' file system, the same for a host and a viewer.</summary>
public static class ClipFileSystem
{
    /// <summary>The session options every Windows side uses: files are opened and marked as below.</summary>
    public static ClipSyncOptions Options(string staging, bool acceptDrops) => new()
    {
        Staging = staging,
        AcceptDrops = acceptDrops,
        OpenToSend = OpenToSend,
        FileReceived = MarkFromAnotherComputer,
    };

    /// <summary>
    /// Opens a copied or dropped file to send: the file itself, never what a link or junction put in its place since
    /// it was listed (nothing outside what was copied is read). Anything but a plain file is refused.
    /// </summary>
    public static FileStream OpenToSend(string path)
    {
        const uint genericRead = 0x80000000, shareAll = 0x7, openExisting = 3;
        const uint openReparsePoint = 0x00200000, overlapped = 0x40000000, sequentialScan = 0x08000000;
        const uint directory = 0x10, reparsePoint = 0x400;
        var handle = CreateFile(Path.GetFullPath(path), genericRead, shareAll, IntPtr.Zero, openExisting, openReparsePoint | overlapped | sequentialScan, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException($"The file couldn't be opened ({new Win32Exception(Marshal.GetLastWin32Error()).Message}).");
        try
        {
            if (!GetFileInformationByHandle(handle, out var info) || (info.Attributes & (directory | reparsePoint)) != 0)
                throw new IOException("Not a plain file: it isn't sent.");
            return new FileStream(handle, FileAccess.Read, 1, isAsync: true);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    /// <summary>
    /// Marks a received file as from another computer (the Mark of the Web: a <c>Zone.Identifier</c> stream saying the
    /// Internet zone), so Windows warns before running a program, script or shortcut that arrived this way. A drive
    /// that can't hold the mark (not NTFS) leaves the file unmarked.
    /// </summary>
    public static void MarkFromAnotherComputer(string path)
    {
        try { File.WriteAllBytes(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n"u8.ToArray()); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException) { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public long Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateFileW", SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
}
