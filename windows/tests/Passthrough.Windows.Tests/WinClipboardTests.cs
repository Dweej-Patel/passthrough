using System.Text;
using Passthrough.Core.ClipSync;
using Passthrough.Windows.ClipSync;
using Xunit;

namespace Passthrough.Windows.Tests;

public sealed class WinClipboardTests
{
    /// <summary>A 3x2 bitmap as an app puts it on the clipboard (CF_DIB: 40-byte header, 32 bits, bottom-up, no alpha).</summary>
    private static byte[] Dib(out byte[][] rowsTopDown)
    {
        byte[] Pixel(byte b, byte g, byte r) => [b, g, r, 0];
        rowsTopDown =
        [
            [.. Pixel(0, 0, 255), .. Pixel(0, 255, 0), .. Pixel(255, 0, 0)],
            [.. Pixel(10, 20, 30), .. Pixel(255, 255, 255), .. Pixel(0, 0, 0)],
        ];
        var dib = new byte[40 + 24];
        BitConverter.TryWriteBytes(dib.AsSpan(0), 40);
        BitConverter.TryWriteBytes(dib.AsSpan(4), 3);
        BitConverter.TryWriteBytes(dib.AsSpan(8), 2);
        BitConverter.TryWriteBytes(dib.AsSpan(12), (ushort)1);
        BitConverter.TryWriteBytes(dib.AsSpan(14), (ushort)32);
        rowsTopDown[1].CopyTo(dib, 40);
        rowsTopDown[0].CopyTo(dib, 52);
        return dib;
    }

    [Fact]
    public void ACopiedBitmap_BecomesAPng_AndAPngBecomesTheBitmapWindowsAppsPaste()
    {
        var clipboard = new WinClipboard();
        var png = clipboard.PngFromDib(Dib(out var rows));
        Assert.NotNull(png);
        Assert.Equal([0x89, (byte)'P', (byte)'N', (byte)'G'], png![..4]);
        var back = clipboard.DibFromPng(png);
        Assert.NotNull(back);
        Assert.Equal(124, BitConverter.ToInt32(back!, 0)); // BITMAPV5HEADER
        Assert.Equal((3, 2), (BitConverter.ToInt32(back, 4), BitConverter.ToInt32(back, 8)));
        Assert.Equal(32, BitConverter.ToUInt16(back, 14));
        Assert.Equal(124 + 24, back.Length);
        // Bottom-up, blue-green-red, now opaque.
        for (var row = 0; row < 2; row++)
        for (var x = 0; x < 3; x++)
        {
            var expected = rows[1 - row].AsSpan(x * 4, 3).ToArray();
            Assert.Equal(expected, back[(124 + row * 12 + x * 4)..(124 + row * 12 + x * 4 + 3)]);
            Assert.Equal(255, back[124 + row * 12 + x * 4 + 3]);
        }
    }

    [Fact]
    public void WhatIsntAPicture_IsNoPicture()
    {
        var clipboard = new WinClipboard();
        Assert.Null(clipboard.PngFromDib([1, 2, 3]));
        Assert.Null(clipboard.PngFromDib(new byte[64]));
        Assert.Null(clipboard.DibFromPng("not a png at all"u8.ToArray()));
        Assert.Null(clipboard.DibFromPng([]));
    }

    /// <summary>
    /// Writes to this session's real clipboard and reads it back, so it runs only when asked for
    /// (<c>PASSTHROUGH_CLIPBOARD_TESTS=1</c>) and only when the clipboard holds nothing but plain text, which it puts back.
    /// </summary>
    [Fact]
    public async Task OnTheRealClipboard_WhatSyncPutsThereIsThere_MarkedSoItIsntSentBack()
    {
        if (Environment.GetEnvironmentVariable("PASSTHROUGH_CLIPBOARD_TESTS") != "1") return;
        var clipboard = new WinClipboard();
        var before = await clipboard.CurrentAsync();
        string? restore = null;
        if (before is ClipSnapshot.Contents { Payload.Items: var items })
        {
            if (items.Any(i => i.Format != ClipFormat.Text)) return; // more than text: left alone
            restore = Encoding.UTF8.GetString(items[0].Data.Span);
        }
        var seen = new List<ClipSnapshot>();
        using var watch = clipboard.Watch(s => { lock (seen) seen.Add(s); });
        var folder = Path.Combine(Path.GetTempPath(), "pt-clip-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var png = clipboard.PngFromDib(Dib(out _))!;
            var copy = new ReceivedTransfer(1, ClipKind.Clipboard, 0, 0,
            [
                new ReceivedItem(ClipFormat.Text, "", "synced héllo\r\nline two"u8.ToArray(), null),
                new ReceivedItem(ClipFormat.Html, "", "<b>synced</b>"u8.ToArray(), null),
                new ReceivedItem(ClipFormat.Rtf, "", @"{\rtf1 synced}"u8.ToArray(), null),
                new ReceivedItem(ClipFormat.Png, "", png, null),
            ], null);
            Assert.True(await clipboard.WriteAsync(copy));
            // What this side put there is marked: it reads as nothing to send, and no watcher hears of it.
            Assert.IsType<ClipSnapshot.Nothing>(await clipboard.CurrentAsync());
            Assert.Equal("synced héllo\r\nline two", ReadText());
            Assert.Contains("<b>synced</b>", ReadFormat("HTML Format"));
            Assert.StartsWith(@"{\rtf1 synced}", ReadFormat("Rich Text Format"));
            await Task.Delay(500);
            lock (seen) Assert.Empty(seen);

            // Files: the clipboard points at them, as a copy in Explorer does.
            var file = Path.Combine(folder, "synced.txt");
            File.WriteAllText(file, "x");
            Assert.True(await clipboard.WriteAsync(new ReceivedTransfer(2, ClipKind.Clipboard, 0, 0, [new ReceivedItem(ClipFormat.File, "synced.txt", null, file)], folder)));
            Assert.Equal([file], FileDropList());
            Assert.IsType<ClipSnapshot.Nothing>(await clipboard.CurrentAsync());

            // A copy made by anything else is heard and read: here, plain text put there the ordinary way.
            SetPlainText("copied by a person");
            await Task.Delay(700);
            ClipSnapshot heard;
            lock (seen) heard = Assert.Single(seen);
            var payload = Assert.IsType<ClipSnapshot.Contents>(heard).Payload;
            Assert.Equal("copied by a person", Encoding.UTF8.GetString(payload.Items.Single(i => i.Format == ClipFormat.Text).Data.Span));
        }
        finally
        {
            if (restore is not null) SetPlainText(restore); else Clear();
            Directory.Delete(folder, recursive: true);
        }
    }

    // The clipboard read and written the plain Win32 way, independently of WinClipboard.

    private static string ReadText() => Encoding.Unicode.GetString(Read(13)).Split('\0')[0];
    private static string ReadFormat(string name) => Encoding.UTF8.GetString(Read(Native.RegisterClipboardFormatW(name))).TrimEnd('\0');

    private static byte[] Read(uint format)
    {
        Assert.True(Open());
        try
        {
            var handle = Native.GetClipboardData(format);
            Assert.NotEqual(IntPtr.Zero, handle);
            var bytes = new byte[(int)Native.GlobalSize(handle)];
            System.Runtime.InteropServices.Marshal.Copy(Native.GlobalLock(handle), bytes, 0, bytes.Length);
            Native.GlobalUnlock(handle);
            return bytes;
        }
        finally { Native.CloseClipboard(); }
    }

    private static List<string> FileDropList()
    {
        Assert.True(Open());
        try
        {
            var drop = Native.GetClipboardData(15);
            var files = new List<string>();
            var count = Native.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
            for (uint i = 0; i < count; i++)
            {
                var name = new char[Native.DragQueryFileW(drop, i, null, 0) + 1];
                Native.DragQueryFileW(drop, i, name, (uint)name.Length);
                files.Add(new string(name, 0, name.Length - 1));
            }
            return files;
        }
        finally { Native.CloseClipboard(); }
    }

    private static void SetPlainText(string text)
    {
        Assert.True(Open());
        try
        {
            Native.EmptyClipboard();
            var bytes = Encoding.Unicode.GetBytes(text + "\0");
            var handle = Native.GlobalAlloc(2, (nuint)bytes.Length);
            System.Runtime.InteropServices.Marshal.Copy(bytes, 0, Native.GlobalLock(handle), bytes.Length);
            Native.GlobalUnlock(handle);
            Native.SetClipboardData(13, handle);
        }
        finally { Native.CloseClipboard(); }
    }

    private static void Clear()
    {
        if (!Open()) return;
        Native.EmptyClipboard();
        Native.CloseClipboard();
    }

    private static bool Open()
    {
        for (var i = 0; i < 20; i++)
        {
            if (Native.OpenClipboard(IntPtr.Zero)) return true;
            Thread.Sleep(25);
        }
        return false;
    }

    private static class Native
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr owner);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool CloseClipboard();
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EmptyClipboard();
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr SetClipboardData(uint format, IntPtr handle);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint RegisterClipboardFormatW(string name);
        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint DragQueryFileW(IntPtr drop, uint index, [System.Runtime.InteropServices.Out] char[]? name, uint size);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, nuint bytes);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr handle);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr handle);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern nuint GlobalSize(IntPtr handle);
    }
}
