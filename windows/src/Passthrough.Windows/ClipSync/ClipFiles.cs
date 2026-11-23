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
    /// Opens a copied or dropped file to send: the file itself, never what a symbolic link or junction put in its place
    /// since it was listed (nothing outside what was copied is read). A folder, a link or a junction is refused. A
    /// file that is another kind of reparse point (one a cloud-synced folder keeps, for one) is an ordinary file to its
    /// readers: it is opened the ordinary way, and only if that is the same file.
    /// </summary>
    public static FileStream OpenToSend(string path)
    {
        const uint openReparsePoint = 0x00200000, directory = 0x10, reparsePoint = 0x400;
        const uint symbolicLink = 0xA000000C, mountPoint = 0xA0000003;
        var full = Path.GetFullPath(path);
        var itself = Open(full, openReparsePoint);
        try
        {
            if (!GetFileInformationByHandle(itself, out var info) || (info.Attributes & directory) != 0) throw new IOException("Not a plain file: it isn't sent.");
            if ((info.Attributes & reparsePoint) == 0)
            {
                var stream = new FileStream(itself, FileAccess.Read, 1, isAsync: true);
                itself = null;
                return stream;
            }
            if (!GetFileInformationByHandleEx(itself, 9 /* FileAttributeTagInfo */, out var tag, Marshal.SizeOf<TagInformation>())
                || tag.ReparseTag is symbolicLink or mountPoint)
                throw new IOException("A link, not a file: what it points at isn't sent.");
            // Its contents come through whatever keeps it. The first handle stays open meanwhile, so nothing can be put in its place.
            var through = Open(full, 0);
            try
            {
                if (!GetFileInformationByHandle(through, out var same) || (same.Attributes & directory) != 0
                    || (same.Volume, same.IndexHigh, same.IndexLow) != (info.Volume, info.IndexHigh, info.IndexLow))
                    throw new IOException("Not the file that was listed: it isn't sent.");
                var stream = new FileStream(through, FileAccess.Read, 1, isAsync: true);
                through = null;
                return stream;
            }
            finally { through?.Dispose(); }
        }
        finally { itself?.Dispose(); }
    }

    private static SafeFileHandle Open(string full, uint flags)
    {
        const uint genericRead = 0x80000000, shareAll = 0x7, openExisting = 3, overlapped = 0x40000000, sequentialScan = 0x08000000;
        var handle = CreateFile(full, genericRead, shareAll, IntPtr.Zero, openExisting, flags | overlapped | sequentialScan, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new IOException($"The file couldn't be opened ({new Win32Exception(error).Message}).");
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

    [StructLayout(LayoutKind.Sequential)]
    private struct TagInformation
    {
        public uint Attributes, ReparseTag;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, out TagInformation info, int size);
}
