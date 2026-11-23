using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Passthrough.Core.ClipSync;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Passthrough.Windows.ClipSync;

/// <summary>What is on this PC's clipboard, as clipboard sync sees it.</summary>
public abstract record ClipSnapshot
{
    public sealed record Contents(ClipPayload Payload) : ClipSnapshot;
    /// <summary>Over the clipboard's limits: drag it in instead.</summary>
    public sealed record TooLarge : ClipSnapshot;
    /// <summary>Nothing that syncs (empty, marked secret or not to leave this PC, or put there by sync itself).</summary>
    public sealed record Nothing : ClipSnapshot;
}

/// <summary>
/// This Windows session's clipboard for clipboard sync (protocol/README.md, "Clipboard sync", What syncs): one thread
/// with a hidden window hears each change, reads what may go to the other side, and puts what came from it there.
/// <list type="bullet">
/// <item>Never read: contents an app marks <c>ExcludeClipboardContentFromMonitorProcessing</c>,
/// <c>CanIncludeInClipboardHistory</c> 0, <c>CanUploadToCloudClipboard</c> 0 or <c>Clipboard Viewer Ignore</c>
/// (password managers do), and what this side put there itself (<c>Passthrough Synced</c>).</item>
/// <item>Read: file paths (CF_HDROP; never virtual files), else text, RTF, HTML (without Windows' header) and an image
/// as PNG (an app's own PNG, or its bitmap converted).</item>
/// <item>Written: the same formats, marked <c>Passthrough Synced</c> and <c>CanUploadToCloudClipboard</c> 0, so they
/// aren't sent back or on to this account's other devices.</item>
/// </list>
/// </summary>
public sealed class WinClipboard
{
    private static readonly Lazy<WinClipboard> Instance = new(() => new WinClipboard());

    /// <summary>The one for this process, started when first asked for.</summary>
    public static WinClipboard Shared => Instance.Value;

    /// <summary>How long after a change the clipboard is read: one copy often changes it several times.</summary>
    private const uint SettleMs = 150;
    /// <summary>A received image larger than this is put on the clipboard as PNG only, not decoded to a bitmap.</summary>
    private const long MaxDecodedPixels = 64L << 20;

    private readonly ConcurrentQueue<Action> _work = new();
    private readonly ManualResetEventSlim _ready = new();
    private readonly Lock _lock = new();
    private readonly List<Action<ClipSnapshot>> _watchers = [];
    private readonly Action<string>? _log;
    private IntPtr _window;
    private WndProc? _proc;
    private uint _ownSequence;
    private int _reading;
    private uint _fPng, _fRtf, _fHtml, _fSynced, _fExclude, _fHistory, _fCloud, _fIgnore, _fDropEffect;

    public WinClipboard(Action<string>? log = null)
    {
        _log = log;
        var thread = new Thread(Main) { IsBackground = true, Name = "Passthrough clipboard" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        _ready.Wait(TimeSpan.FromSeconds(5));
    }

    /// <summary>
    /// Tells <paramref name="onChange"/>, on a worker thread, about each change that may sync or is too large to; dispose
    /// the result to stop.
    /// </summary>
    public IDisposable Watch(Action<ClipSnapshot> onChange)
    {
        lock (_lock) _watchers.Add(onChange);
        return new Unwatch(this, onChange);
    }

    private sealed class Unwatch(WinClipboard owner, Action<ClipSnapshot> watcher) : IDisposable
    {
        public void Dispose() { lock (owner._lock) owner._watchers.Remove(watcher); }
    }

    /// <summary>The clipboard as it is now.</summary>
    public async Task<ClipSnapshot> CurrentAsync(CancellationToken cancel = default)
    {
        var raw = await OnThread(Read).ConfigureAwait(false);
        return await Task.Run(() => Build(raw, cancel), cancel).ConfigureAwait(false);
    }

    /// <summary>Puts what came from the other side on the clipboard, marked as synced; false when the clipboard couldn't be opened or nothing fit.</summary>
    public async Task<bool> WriteAsync(ReceivedTransfer transfer)
    {
        var formats = await Task.Run(() => Formats(transfer)).ConfigureAwait(false);
        if (formats.Count == 0) return false;
        return await OnThread(() => Write(formats)).ConfigureAwait(false);
    }

    // MARK: Reading

    /// <param name="Over">Something was there but over its limit, and so left out.</param>
    private sealed record Raw(uint Sequence, bool Excluded, bool Over, IReadOnlyList<string>? Files, string? Text, byte[]? Rtf, byte[]? Html, byte[]? Png, byte[]? Dib);

    private static readonly Raw Empty = new(0, true, false, null, null, null, null, null, null);

    /// <summary>On the clipboard's thread: copies out what may sync. A change while reading makes it nothing (a secret may have just been copied).</summary>
    private Raw Read()
    {
        var before = GetClipboardSequenceNumber();
        _over = false;
        if (!Open()) return Empty;
        try
        {
            var formats = new HashSet<uint>();
            for (uint f = 0; (f = EnumClipboardFormats(f)) != 0;) formats.Add(f);
            if (formats.Count == 0) return Empty;
            if (formats.Contains(_fSynced) || formats.Contains(_fExclude) || formats.Contains(_fIgnore) || IsZero(formats, _fHistory) || IsZero(formats, _fCloud)) return Empty;
            Raw raw;
            if (formats.Contains(CfHDrop)) raw = new Raw(before, false, false, DroppedFiles(), null, null, null, null, null);
            else
            {
                var text = formats.Contains(CfUnicodeText) && Bytes(CfUnicodeText, 2 * (long)ClipSyncWire.MaxClipboardText + 2) is { } utf16
                    ? Encoding.Unicode.GetString(utf16).Split('\0')[0] : null;
                raw = new Raw(before, false, false, null, text,
                    formats.Contains(_fRtf) ? TrimNul(Bytes(_fRtf, (long)ClipSyncWire.MaxClipboardText + 1)) : null,
                    formats.Contains(_fHtml) ? Bytes(_fHtml, (long)ClipSyncWire.MaxClipboardText + 4096) : null,
                    formats.Contains(_fPng) ? Bytes(_fPng, (long)ClipSyncWire.MaxClipboardImage) : null,
                    // A bitmap only when the app gave no PNG of its own: 256 MiB of pixels at most are looked at.
                    !formats.Contains(_fPng) && formats.Contains(CfDib) ? Bytes(CfDib, 256L << 20) : null);
            }
            return GetClipboardSequenceNumber() == before ? raw with { Over = _over } : Empty;
        }
        finally { CloseClipboard(); }
    }

    private static bool IsZero(HashSet<uint> formats, uint format) =>
        formats.Contains(format) && Bytes(format, 64) is { Length: >= 4 } value && BitConverter.ToUInt32(value) == 0;

    private static byte[]? TrimNul(byte[]? bytes)
    {
        if (bytes is null) return null;
        var end = Array.IndexOf(bytes, (byte)0);
        return end < 0 ? bytes : bytes[..end];
    }

    /// <summary>A format's bytes; null when it isn't there, is empty, or is over <paramref name="max"/> (then <see cref="_over"/> is set).</summary>
    private static byte[]? Bytes(uint format, long max)
    {
        var handle = GetClipboardData(format);
        if (handle == IntPtr.Zero) return null;
        var size = (long)GlobalSize(handle);
        if (size <= 0) return null;
        if (size > max) { _over = true; return null; }
        var pointer = GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            var bytes = new byte[size];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { GlobalUnlock(handle); }
    }

    /// <summary>Set by <see cref="Bytes"/> on the clipboard's thread while one read runs: something was there but too large.</summary>
    [ThreadStatic] private static bool _over;

    private static List<string> DroppedFiles()
    {
        var files = new List<string>();
        var drop = GetClipboardData(CfHDrop);
        if (drop == IntPtr.Zero) return files;
        var count = DragQueryFile(drop, 0xFFFFFFFF, null, 0);
        for (uint i = 0; i < count; i++)
        {
            var length = DragQueryFile(drop, i, null, 0);
            var name = new char[length + 1];
            if (DragQueryFile(drop, i, name, (uint)name.Length) > 0) files.Add(new string(name, 0, (int)length));
        }
        return files;
    }

    /// <summary>Off the clipboard's thread: walks folders, converts a bitmap, applies the limits.</summary>
    private ClipSnapshot Build(Raw raw, CancellationToken cancel = default)
    {
        if (raw.Excluded) return new ClipSnapshot.Nothing();
        if (raw.Files is { Count: > 0 } files)
        {
            var (payload, failed) = ClipFiles.Collect(files, ClipSyncWire.MaxClipboardFiles, ClipSyncWire.MaxItems, cancel);
            if (failed == ClipFiles.Failure.TooLarge) return new ClipSnapshot.TooLarge();
            return payload is { Items.Count: > 0 } ? new ClipSnapshot.Contents(payload) : new ClipSnapshot.Nothing();
        }
        var items = new List<ClipItem>();
        var over = raw.Over;
        void Add(ClipFormat format, byte[]? data, ulong cap)
        {
            if (data is not { Length: > 0 }) return;
            if ((ulong)data.Length > cap) { over = true; return; }
            items.Add(ClipItem.Inline(format, data));
        }
        Add(ClipFormat.Text, raw.Text is { Length: > 0 } text ? Encoding.UTF8.GetBytes(text) : null, ClipSyncWire.MaxClipboardText);
        Add(ClipFormat.Rtf, raw.Rtf, ClipSyncWire.MaxClipboardText);
        Add(ClipFormat.Html, raw.Html is { } block ? ClipHtml.FromClipboard(block) : null, ClipSyncWire.MaxClipboardText);
        Add(ClipFormat.Png, raw.Png ?? (raw.Dib is { } dib ? PngFromDib(dib) : null), ClipSyncWire.MaxClipboardImage);
        if (items.Count == 0) return over ? new ClipSnapshot.TooLarge() : new ClipSnapshot.Nothing();
        return new ClipSnapshot.Contents(new ClipPayload(items));
    }

    /// <summary>A clipboard bitmap (CF_DIB: the header, any masks or palette, the pixels) as PNG, through Windows' own codecs; null when it can't be read.</summary>
    internal byte[]? PngFromDib(byte[] dib)
    {
        try
        {
            if (dib.Length < 40) return null;
            var headerSize = BitConverter.ToInt32(dib, 0);
            var bits = BitConverter.ToUInt16(dib, 14);
            var compression = BitConverter.ToInt32(dib, 16);
            var used = BitConverter.ToInt32(dib, 32);
            var extra = headerSize == 40 && compression == 3 ? 12 : headerSize == 40 && compression == 6 ? 16 : 0;
            var palette = (used > 0 ? used : bits <= 8 ? 1 << bits : 0) * 4;
            var offset = 14L + headerSize + extra + palette;
            if (headerSize < 40 || offset > dib.Length + 14L) return null;
            // A .bmp file is this block behind a 14-byte header.
            var bmp = new byte[14 + dib.Length];
            bmp[0] = (byte)'B';
            bmp[1] = (byte)'M';
            BitConverter.TryWriteBytes(bmp.AsSpan(2), bmp.Length);
            BitConverter.TryWriteBytes(bmp.AsSpan(10), (int)offset);
            dib.CopyTo(bmp, 14);
            return Task.Run(async () =>
            {
                using var source = new InMemoryRandomAccessStream();
                await source.WriteAsync(bmp.AsBuffer());
                source.Seek(0);
                var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.BmpDecoderId, source);
                using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
                using var target = new InMemoryRandomAccessStream();
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, target);
                encoder.SetSoftwareBitmap(bitmap);
                await encoder.FlushAsync();
                var png = new byte[target.Size];
                target.Seek(0);
                await target.ReadAsync(png.AsBuffer(), (uint)png.Length, InputStreamOptions.None);
                return png;
            }).GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException or OutOfMemoryException or FormatException)
        {
            _log?.Invoke($"clipsync: the copied picture couldn't be converted ({e.GetType().Name})");
            return null;
        }
    }

    /// <summary>A received PNG as a clipboard bitmap (CF_DIBV5, 32 bits with alpha, bottom-up); null when it can't be decoded or is too large to.</summary>
    internal byte[]? DibFromPng(byte[] png)
    {
        try
        {
            return Task.Run(async () =>
            {
                using var source = new InMemoryRandomAccessStream();
                await source.WriteAsync(png.AsBuffer());
                source.Seek(0);
                // The PNG decoder only, and its real size checked before any pixel is asked for.
                var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.PngDecoderId, source);
                if (decoder.PixelWidth < 1 || decoder.PixelHeight < 1 || (long)decoder.PixelWidth * decoder.PixelHeight > MaxDecodedPixels) return null;
                var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(),
                    ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
                var pixels = data.DetachPixelData();
                int width = (int)decoder.PixelWidth, height = (int)decoder.PixelHeight, stride = width * 4;
                if (pixels.Length < stride * height) return null;
                const int header = 124;
                var dib = new byte[header + pixels.Length];
                var h = dib.AsSpan();
                BitConverter.TryWriteBytes(h, header);
                BitConverter.TryWriteBytes(h[4..], width);
                BitConverter.TryWriteBytes(h[8..], height);
                BitConverter.TryWriteBytes(h[12..], (ushort)1);
                BitConverter.TryWriteBytes(h[14..], (ushort)32);
                BitConverter.TryWriteBytes(h[16..], 3); // BI_BITFIELDS
                BitConverter.TryWriteBytes(h[20..], stride * height);
                BitConverter.TryWriteBytes(h[40..], 0x00FF0000u);
                BitConverter.TryWriteBytes(h[44..], 0x0000FF00u);
                BitConverter.TryWriteBytes(h[48..], 0x000000FFu);
                BitConverter.TryWriteBytes(h[52..], 0xFF000000u);
                BitConverter.TryWriteBytes(h[56..], 0x73524742u); // LCS_sRGB
                BitConverter.TryWriteBytes(h[108..], 4); // LCS_GM_IMAGES
                for (var row = 0; row < height; row++)
                    pixels.AsSpan((height - 1 - row) * stride, stride).CopyTo(h[(header + row * stride)..]);
                return dib;
            }).GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException or OutOfMemoryException or FormatException)
        {
            _log?.Invoke($"clipsync: the received picture goes on the clipboard as PNG only ({e.GetType().Name})");
            return null;
        }
    }

    // MARK: Writing

    /// <summary>Off the clipboard's thread: each clipboard format's bytes for a received transfer.</summary>
    private List<(uint Format, byte[] Bytes)> Formats(ReceivedTransfer transfer)
    {
        var formats = new List<(uint, byte[])>();
        var files = transfer.TopLevel;
        if (files.Count > 0)
        {
            // DROPFILES: the offset of the list, a point, two flags (wide characters), then each path and a last NUL.
            var list = Encoding.Unicode.GetBytes(string.Join('\0', files) + "\0\0");
            var drop = new byte[20 + list.Length];
            BitConverter.TryWriteBytes(drop.AsSpan(), 20);
            BitConverter.TryWriteBytes(drop.AsSpan(16), 1);
            list.CopyTo(drop, 20);
            formats.Add((CfHDrop, drop));
            formats.Add((_fDropEffect, BitConverter.GetBytes(1 /* DROPEFFECT_COPY */)));
        }
        else
        {
            if (transfer.Data(ClipFormat.Text) is { Length: > 0 } text)
            {
                try { formats.Add((CfUnicodeText, Encoding.Unicode.GetBytes(new UTF8Encoding(false, true).GetString(text) + "\0"))); }
                catch (DecoderFallbackException) { }
            }
            if (transfer.Data(ClipFormat.Rtf) is { Length: > 0 } rtf) formats.Add((_fRtf, [.. rtf, 0]));
            if (transfer.Data(ClipFormat.Html) is { Length: > 0 } html) formats.Add((_fHtml, ClipHtml.ToClipboard(html)));
            if (transfer.Data(ClipFormat.Png) is { Length: > 0 } png)
            {
                formats.Add((_fPng, png));
                if (DibFromPng(png) is { } dib) formats.Add((CfDibV5, dib));
            }
        }
        if (formats.Count == 0) return formats;
        formats.Add((_fSynced, [1]));
        formats.Add((_fCloud, BitConverter.GetBytes(0)));
        return formats;
    }

    /// <summary>On the clipboard's thread.</summary>
    private bool Write(List<(uint Format, byte[] Bytes)> formats)
    {
        if (!Open()) return false;
        try
        {
            if (!EmptyClipboard()) return false;
            var placed = false;
            foreach (var (format, bytes) in formats)
            {
                var handle = GlobalAlloc(0x0002 /* GMEM_MOVEABLE */, (nuint)bytes.Length);
                if (handle == IntPtr.Zero) continue;
                var pointer = GlobalLock(handle);
                if (pointer == IntPtr.Zero) { GlobalFree(handle); continue; }
                Marshal.Copy(bytes, 0, pointer, bytes.Length);
                GlobalUnlock(handle);
                // The clipboard owns the memory once it takes it.
                if (SetClipboardData(format, handle) == IntPtr.Zero) GlobalFree(handle);
                else placed = true;
            }
            return placed;
        }
        finally
        {
            CloseClipboard();
            _ownSequence = GetClipboardSequenceNumber();
        }
    }

    private bool Open()
    {
        // Another program may have it open for a moment.
        for (var i = 0; i < 10; i++)
        {
            if (OpenClipboard(_window)) return true;
            Thread.Sleep(20);
        }
        _log?.Invoke("clipsync: the clipboard is busy");
        return false;
    }

    // MARK: The thread

    private Task<T> OnThread<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        _work.Enqueue(() =>
        {
            try { done.SetResult(work()); }
            catch (Exception e) when (e is not OutOfMemoryException) { done.SetException(e); }
        });
        if (_window == IntPtr.Zero || !PostMessage(_window, WmWork, IntPtr.Zero, IntPtr.Zero)) done.TrySetException(new InvalidOperationException("The clipboard's thread isn't running."));
        return done.Task;
    }

    private void Main()
    {
        _fPng = RegisterClipboardFormat("PNG");
        _fRtf = RegisterClipboardFormat("Rich Text Format");
        _fHtml = RegisterClipboardFormat("HTML Format");
        _fSynced = RegisterClipboardFormat("Passthrough Synced");
        _fExclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        _fHistory = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        _fCloud = RegisterClipboardFormat("CanUploadToCloudClipboard");
        _fIgnore = RegisterClipboardFormat("Clipboard Viewer Ignore");
        _fDropEffect = RegisterClipboardFormat("Preferred DropEffect");
        _proc = Proc;
        var cls = new WndClassEx
        {
            Size = Marshal.SizeOf<WndClassEx>(), Proc = Marshal.GetFunctionPointerForDelegate(_proc), Instance = GetModuleHandle(null),
            ClassName = "PassthroughClipboard" + Environment.ProcessId + "_" + Environment.TickCount64,
        };
        if (RegisterClassEx(ref cls) != 0)
            _window = CreateWindowEx(0, cls.ClassName, "", 0, 0, 0, 0, 0, new IntPtr(-3) /* HWND_MESSAGE */, IntPtr.Zero, cls.Instance, IntPtr.Zero);
        if (_window != IntPtr.Zero) AddClipboardFormatListener(_window);
        else _log?.Invoke("clipsync: no window to hear the clipboard with");
        _ready.Set();
        if (_window == IntPtr.Zero) return;
        while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0) DispatchMessage(ref message);
    }

    private IntPtr Proc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
    {
        switch (message)
        {
            case WmClipboardUpdate:
                // Our own write isn't a change to send; anything else is read once it has settled.
                if (GetClipboardSequenceNumber() != _ownSequence) SetTimer(window, 1, SettleMs, IntPtr.Zero);
                return IntPtr.Zero;
            case WmTimer:
                KillTimer(window, 1);
                Changed();
                return IntPtr.Zero;
            case WmWork:
                while (_work.TryDequeue(out var work)) work();
                return IntPtr.Zero;
        }
        return DefWindowProc(window, message, wParam, lParam);
    }

    private void Changed()
    {
        bool anyone;
        lock (_lock) anyone = _watchers.Count > 0;
        if (!anyone || GetClipboardSequenceNumber() == _ownSequence) return;
        var raw = Read();
        var reading = Interlocked.Increment(ref _reading);
        _ = Task.Run(() =>
        {
            ClipSnapshot snapshot;
            try { snapshot = Build(raw); }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                _log?.Invoke($"clipsync: the clipboard couldn't be read ({e.GetType().Name})");
                return;
            }
            // Something newer was copied meanwhile: that one is told instead.
            if (reading != Volatile.Read(ref _reading) || snapshot is ClipSnapshot.Nothing) return;
            List<Action<ClipSnapshot>> watchers;
            lock (_lock) watchers = [.. _watchers];
            foreach (var watcher in watchers)
            {
                try { watcher(snapshot); }
                catch (Exception e) when (e is not OutOfMemoryException) { _log?.Invoke($"clipsync: a clipboard watcher failed ({e.GetType().Name})"); }
            }
        });
    }

    // MARK: Native

    private const uint CfDib = 8, CfUnicodeText = 13, CfHDrop = 15, CfDibV5 = 17;
    private const uint WmTimer = 0x0113, WmClipboardUpdate = 0x031D, WmWork = 0x8001;

    private delegate IntPtr WndProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct Message { public IntPtr Window; public uint Id; public IntPtr WParam, LParam; public uint Time; public int X, Y; public uint Private; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClassEx
    {
        public int Size;
        public uint Style;
        public IntPtr Proc;
        public int ClassExtra, WindowExtra;
        public IntPtr Instance, Icon, Cursor, Background;
        public string? MenuName;
        public string ClassName;
        public IntPtr SmallIcon;
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool EmptyClipboard();
    [DllImport("user32.dll")] private static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] private static extern IntPtr SetClipboardData(uint format, IntPtr handle);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern bool AddClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterClipboardFormatW")] private static extern uint RegisterClipboardFormat(string name);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "DragQueryFileW")] private static extern uint DragQueryFile(IntPtr drop, uint index, [Out] char[]? name, uint size);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern nuint GlobalSize(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleHandleW")] private static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterClassExW")] private static extern ushort RegisterClassEx(ref WndClassEx cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateWindowExW")]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll", EntryPoint = "DefWindowProcW")] private static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "GetMessageW")] private static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll", EntryPoint = "DispatchMessageW")] private static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern nuint SetTimer(IntPtr window, nuint id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] private static extern bool KillTimer(IntPtr window, nuint id);
}
