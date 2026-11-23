using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Passthrough.Windows.ClipSync;

public enum DropOutcome
{
    /// <summary>Whatever was at the point took the files.</summary>
    Dropped,
    /// <summary>Nothing there took them, or the drag couldn't start.</summary>
    NotTaken,
    /// <summary>The drag got no answer in time: whatever is there may still be taking them.</summary>
    TimedOut,
}

/// <summary>
/// Drops files at a point on this session's desktop as if someone had dragged them there (protocol/README.md,
/// "Clipboard sync", Drops): a tiny window of Passthrough's own takes a real mouse press, starts Windows' own
/// drag-and-drop (OLE <c>DoDragDrop</c>) with the files, and the pointer is moved to the point and let go with
/// <c>SendInput</c>, so whatever is there (an Explorer folder, the desktop, a mail window) takes them its own way.
/// Only copying is offered, so the files stay where they were put. It runs at the tray app's own integrity: a window
/// of an elevated program doesn't take the drop, and nothing happens on the lock screen.
/// </summary>
public static class DropPerformer
{
    /// <summary>How far left of the point the drag starts, in pixels.</summary>
    private const int Lead = 60;
    private const int Side = 24;
    private static readonly Lock Busy = new();
    /// <summary>Drops waiting for the one in progress: past this many, a new one is not taken.</summary>
    public const int MaxWaiting = 3;
    private static int _waiting;

    /// <summary>What is at a point: the top-level window there and the process that owns it.</summary>
    public readonly record struct Target(IntPtr Window, uint Process);

    /// <summary>The point (<paramref name="x"/>, <paramref name="y"/>), each 0…65535 across the session's virtual desktop, in pixels.</summary>
    public static (int X, int Y) PointOf(ushort x, ushort y)
    {
        using var aware = new PerMonitorAware();
        var (left, top, width, height) = VirtualDesktop();
        return (left + (int)Math.Round(x / 65535.0 * (width - 1)), top + (int)Math.Round(y / 65535.0 * (height - 1)));
    }

    /// <summary>What's at (<paramref name="x"/>, <paramref name="y"/>) now; null when nothing is.</summary>
    public static Target? At(int x, int y)
    {
        using var aware = new PerMonitorAware();
        var window = WindowFromPoint(new Point { X = x, Y = y });
        if (window == IntPtr.Zero) return null;
        var root = GetAncestor(window, 2 /* GA_ROOT */);
        if (root == IntPtr.Zero) root = window;
        GetWindowThreadProcessId(root, out var pid);
        return new Target(root, pid);
    }

    /// <summary>
    /// Drags <paramref name="paths"/> to (<paramref name="x"/>, <paramref name="y"/>) and lets go; blocks until the drop
    /// is over or <paramref name="limit"/> passes. One at a time: the pointer can only be in one place.
    /// </summary>
    public static DropOutcome Drop(IReadOnlyList<string> paths, int x, int y, TimeSpan limit, Action<string>? log = null)
    {
        if (paths.Count == 0) return DropOutcome.NotTaken;
        if (Interlocked.Increment(ref _waiting) > MaxWaiting + 1)
        {
            Interlocked.Decrement(ref _waiting);
            log?.Invoke("drop: too many drops are waiting; this one isn't dragged");
            return DropOutcome.NotTaken;
        }
        try { return DropNow(paths, x, y, limit, log); }
        finally { Interlocked.Decrement(ref _waiting); }
    }

    private static DropOutcome DropNow(IReadOnlyList<string> paths, int x, int y, TimeSpan limit, Action<string>? log)
    {
        lock (Busy)
        {
            // Someone holding a mouse button (the viewer, mid-drag on this desktop) would have that drag let go where
            // ours starts: wait for the button to come up, and if it doesn't, nothing is dragged.
            var waited = Environment.TickCount64;
            while (AnyButtonDown())
            {
                if (Environment.TickCount64 - waited > ButtonWaitMs)
                {
                    log?.Invoke("drop: a mouse button is held down; the files aren't dragged");
                    return DropOutcome.NotTaken;
                }
                Thread.Sleep(50);
            }
            var run = new Run(paths, x, y, limit, log);
            var thread = new Thread(run.Main) { IsBackground = true, Name = "Passthrough drop" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            if (!thread.Join(limit + TimeSpan.FromSeconds(5))) return DropOutcome.TimedOut;
            return run.Outcome;
        }
    }

    private sealed class Run(IReadOnlyList<string> paths, int x, int y, TimeSpan limit, Action<string>? log) : IDropSource
    {
        private readonly ManualResetEventSlim _pressed = new();
        private volatile bool _cancel;
        private volatile bool _over;
        private IntPtr _window;
        private IntPtr _data;
        private WndProc? _proc;

        public DropOutcome Outcome { get; private set; } = DropOutcome.NotTaken;

        public void Main()
        {
            using var aware = new PerMonitorAware();
            var ole = OleInitialize(IntPtr.Zero);
            if (ole < 0) { log?.Invoke($"drop: OLE didn't start ({ole:X8})"); return; }
            try
            {
                _data = DataObject(paths);
                if (_data == IntPtr.Zero) { log?.Invoke("drop: the files couldn't be offered"); return; }
                // Start beside the point, on the same monitor, so the drop target isn't under our window.
                var (left, top, width, height) = MonitorAt(x, y);
                var startX = x - Lead;
                if (startX < left + Side) startX = x + Lead;
                startX = Math.Clamp(startX, left + Side, left + width - Side);
                var startY = Math.Clamp(y, top + Side, top + height - Side);
                _window = MakeWindow(startX - Side / 2, startY - Side / 2);
                if (_window == IntPtr.Zero) { log?.Invoke("drop: no window to drag from"); return; }
                // The press must land on our own window, or it clicks whatever is there.
                if (WindowFromPoint(new Point { X = startX, Y = startY }) != _window)
                {
                    log?.Invoke("drop: something covers the window the drag starts from");
                    return;
                }
                var pointer = new Thread(() => MovePointer(startX, startY)) { IsBackground = true, Name = "Passthrough drop pointer" };
                pointer.Start();
                while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
                {
                    TranslateMessage(ref message);
                    DispatchMessage(ref message);
                }
                _over = true;
                pointer.Join(TimeSpan.FromSeconds(2));
            }
            catch (Exception e) when (e is COMException or Win32Exception or InvalidOperationException)
            {
                log?.Invoke($"drop: failed ({e.GetType().Name} {e.HResult:X8})");
            }
            finally
            {
                _over = true;
                if (_window != IntPtr.Zero) DestroyWindow(_window);
                if (_data != IntPtr.Zero) Marshal.Release(_data);
                OleUninitialize();
            }
        }

        /// <summary>The pointer's path, off the window's thread: the drag runs a modal loop on that one meanwhile.</summary>
        private void MovePointer(int startX, int startY)
        {
            var started = Environment.TickCount64;
            Thread.Sleep(30);
            Mouse(startX, startY, MouseMove);
            Thread.Sleep(30);
            Mouse(startX, startY, MouseMove | LeftDown);
            // If the press doesn't reach our window, it is let go where it is and nothing is dragged.
            if (!_pressed.Wait(TimeSpan.FromMilliseconds(500)))
            {
                Mouse(startX, startY, MouseMove | LeftUp);
                log?.Invoke("drop: the press didn't reach the window the drag starts from");
                PostMessage(_window, WmClose, IntPtr.Zero, IntPtr.Zero);
                return;
            }
            Thread.Sleep(60);
            const int steps = 16;
            for (var i = 1; i <= steps && !_over; i++)
            {
                Mouse(startX + (x - startX) * i / steps, startY + (y - startY) * i / steps, MouseMove);
                Thread.Sleep(12);
            }
            // A moment over the target, as a hand would pause, so it accepts.
            Mouse(x, y, MouseMove);
            Thread.Sleep(80);
            Mouse(x + 1, y, MouseMove);
            Thread.Sleep(20);
            Mouse(x, y, MouseMove);
            Thread.Sleep(150);
            if (!_over) Mouse(x, y, MouseMove | LeftUp);
            // No answer in time: the drag is called off (the button is already up; a nudge makes OLE ask the source again).
            while (!_over && Environment.TickCount64 - started < limit.TotalMilliseconds) Thread.Sleep(50);
            if (_over) return;
            _cancel = true;
            Outcome = DropOutcome.TimedOut;
            Mouse(x + 1, y, MouseMove);
            Mouse(x, y, MouseMove | LeftUp);
        }

        private IntPtr Proc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
        {
            switch (message)
            {
                case WmLButtonDown:
                    _pressed.Set();
                    var result = DoDragDrop(_data, this, DropEffectCopy, out var effect);
                    if (Outcome != DropOutcome.TimedOut) Outcome = result == DragDropSDrop && effect != 0 ? DropOutcome.Dropped : DropOutcome.NotTaken;
                    log?.Invoke($"drop: the drag ended ({result:X8}, effect {effect})");
                    PostQuitMessage(0);
                    return IntPtr.Zero;
                case WmClose:
                    PostQuitMessage(0);
                    return IntPtr.Zero;
                case WmMouseActivate:
                    return new IntPtr(3); // MA_NOACTIVATE: whatever had the keyboard keeps it
            }
            return DefWindowProc(window, message, wParam, lParam);
        }

        private IntPtr MakeWindow(int left, int top)
        {
            _proc = Proc;
            var name = "PassthroughDropSource";
            var cls = new WndClassEx
            {
                Size = Marshal.SizeOf<WndClassEx>(), Proc = Marshal.GetFunctionPointerForDelegate(_proc), Instance = GetModuleHandle(null),
                ClassName = name + Environment.CurrentManagedThreadId + "_" + Environment.TickCount64,
            };
            if (RegisterClassEx(ref cls) == 0) return IntPtr.Zero;
            var window = CreateWindowEx(ExTopmost | ExToolWindow | ExNoActivate | ExLayered, cls.ClassName, "", WsPopup, left, top, Side, Side,
                IntPtr.Zero, IntPtr.Zero, cls.Instance, IntPtr.Zero);
            if (window == IntPtr.Zero) return IntPtr.Zero;
            // Nearly invisible, but not fully: a fully transparent window lets the press through to what's under it.
            SetLayeredWindowAttributes(window, 0, 2, 2 /* LWA_ALPHA */);
            SetWindowPos(window, new IntPtr(-1) /* HWND_TOPMOST */, left, top, Side, Side, 0x0010 /* SWP_NOACTIVATE */ | 0x0040 /* SWP_SHOWWINDOW */);
            return window;
        }

        // IDropSource

        public int QueryContinueDrag(int escapePressed, int keyState)
        {
            if (_cancel || escapePressed != 0) return DragDropSCancel;
            return (keyState & 0x1 /* MK_LBUTTON */) == 0 ? DragDropSDrop : 0;
        }

        public int GiveFeedback(int effect) => DragDropSUseDefaultCursors;
    }

    /// <summary>The shell's own data object for <paramref name="paths"/> (file paths and item ids, as a drag from Explorer carries); zero when it can't be made.</summary>
    private static IntPtr DataObject(IReadOnlyList<string> paths)
    {
        var ids = new List<IntPtr>();
        try
        {
            foreach (var path in paths)
            {
                if (SHParseDisplayName(path, IntPtr.Zero, out var id, 0, out _) != 0 || id == IntPtr.Zero) return IntPtr.Zero;
                ids.Add(id);
            }
            if (SHCreateShellItemArrayFromIDLists((uint)ids.Count, [.. ids], out var items) != 0 || items is null) return IntPtr.Zero;
            try
            {
                var handler = BhidDataObject;
                var iid = IidDataObject;
                return items.BindToHandler(IntPtr.Zero, ref handler, ref iid, out var data) == 0 ? data : IntPtr.Zero;
            }
            finally { Marshal.ReleaseComObject(items); }
        }
        finally
        {
            foreach (var id in ids) Marshal.FreeCoTaskMem(id);
        }
    }

    // MARK: Downloads

    /// <summary>
    /// Files that couldn't be dropped go to Downloads under free names and are shown there: moved, or copied when
    /// whatever was at the point may still be reading them. False when none got there.
    /// </summary>
    public static bool SaveToDownloads(IReadOnlyList<string> paths, bool copy, Action<string>? log = null)
    {
        if (SHGetKnownFolderPath(Downloads, 0, IntPtr.Zero, out var raw) != 0) return false;
        var downloads = Marshal.PtrToStringUni(raw)!;
        Marshal.FreeCoTaskMem(raw);
        var saved = new List<string>();
        foreach (var path in paths)
        {
            try
            {
                var name = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar));
                var target = Path.Combine(downloads, name);
                for (var n = 2; File.Exists(target) || Directory.Exists(target); n++)
                    target = Path.Combine(downloads, $"{Path.GetFileNameWithoutExtension(name)} {n}{Path.GetExtension(name)}");
                if (Directory.Exists(path))
                {
                    if (copy) CopyFolder(path, target); else MoveFolder(path, target);
                }
                else if (copy) File.Copy(path, target);
                else File.Move(path, target);
                saved.Add(target);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { log?.Invoke($"drop: one item didn't reach Downloads ({e.GetType().Name})"); }
        }
        if (saved.Count == 0) return false;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{saved[0]}\"") { UseShellExecute = false })?.Dispose(); }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException) { }
        return true;
    }

    private static void MoveFolder(string from, string to)
    {
        // Directory.Move can't cross volumes.
        if (string.Equals(Path.GetPathRoot(Path.GetFullPath(from)), Path.GetPathRoot(Path.GetFullPath(to)), StringComparison.OrdinalIgnoreCase)) Directory.Move(from, to);
        else
        {
            CopyFolder(from, to);
            Directory.Delete(from, recursive: true);
        }
    }

    private static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var folder in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, folder)));
        foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories)) File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
    }

    // MARK: Native

    private const uint MouseMove = 0x0001, LeftDown = 0x0002, LeftUp = 0x0004, Absolute = 0x8000, VirtualDesk = 0x4000;
    private const uint WmClose = 0x0010, WmMouseActivate = 0x0021, WmLButtonDown = 0x0201;
    private const uint WsPopup = 0x80000000, ExTopmost = 0x8, ExToolWindow = 0x80, ExLayered = 0x80000, ExNoActivate = 0x08000000;
    private const uint DropEffectCopy = 1;
    private const int DragDropSDrop = 0x00040100, DragDropSCancel = 0x00040101, DragDropSUseDefaultCursors = 0x00040102;
    private static readonly Guid BhidDataObject = new("B8C0BD9F-ED24-455c-83E6-D5390C4FE8C4");
    private static readonly Guid IidDataObject = new("0000010e-0000-0000-C000-000000000046");
    private static readonly Guid Downloads = new("374DE290-123F-4565-9164-39C4925E467B");

    /// <summary>How long a held mouse button is waited for before a drop gives up on dragging.</summary>
    private const int ButtonWaitMs = 4000;

    /// <summary>Whether any mouse button is down now, as this session's input sees it.</summary>
    private static bool AnyButtonDown() =>
        new[] { 0x01, 0x02, 0x04, 0x05, 0x06 }.Any(button => (GetAsyncKeyState(button) & 0x8000) != 0);

    private static (int Left, int Top, int Width, int Height) VirtualDesktop() =>
        (GetSystemMetrics(76), GetSystemMetrics(77), Math.Max(GetSystemMetrics(78), 1), Math.Max(GetSystemMetrics(79), 1));

    private static (int Left, int Top, int Width, int Height) MonitorAt(int x, int y)
    {
        var monitor = MonitorFromPoint(new Point { X = x, Y = y }, 2 /* MONITOR_DEFAULTTONEAREST */);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        return monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info)
            ? (info.Monitor.Left, info.Monitor.Top, info.Monitor.Right - info.Monitor.Left, info.Monitor.Bottom - info.Monitor.Top)
            : VirtualDesktop();
    }

    private static void Mouse(int x, int y, uint flags)
    {
        var (left, top, width, height) = VirtualDesktop();
        var input = new Input
        {
            Type = 0,
            Dx = (int)Math.Round((x - left) * 65535.0 / Math.Max(width - 1, 1)),
            Dy = (int)Math.Round((y - top) * 65535.0 / Math.Max(height - 1, 1)),
            Flags = flags | Absolute | VirtualDesk,
        };
        SendInput(1, ref input, Marshal.SizeOf<Input>());
    }

    /// <summary>Pixels are the screen's own on this thread, whatever the process said about scaling.</summary>
    private readonly struct PerMonitorAware : IDisposable
    {
        private readonly IntPtr _before;
        public PerMonitorAware() => _before = SetThreadDpiAwarenessContext(new IntPtr(-4));
        public void Dispose() { if (_before != IntPtr.Zero) SetThreadDpiAwarenessContext(_before); }
    }

    [ComImport, Guid("00000121-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDropSource
    {
        [PreserveSig] int QueryContinueDrag(int escapePressed, int keyState);
        [PreserveSig] int GiveFeedback(int effect);
    }

    [ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemArray
    {
        [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
    }

    private delegate IntPtr WndProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message { public IntPtr Window; public uint Id; public IntPtr WParam, LParam; public uint Time; public Point Point; public uint Private; }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public int Dx;
        [FieldOffset(12)] public int Dy;
        [FieldOffset(16)] public uint MouseData;
        [FieldOffset(20)] public uint Flags;
        [FieldOffset(24)] public uint Time;
        [FieldOffset(32)] public IntPtr Extra;
    }

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

    [DllImport("ole32.dll")] private static extern int OleInitialize(IntPtr reserved);
    [DllImport("ole32.dll")] private static extern void OleUninitialize();
    [DllImport("ole32.dll")] private static extern int DoDragDrop(IntPtr data, IDropSource source, uint okEffects, out uint effect);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr id, uint attributesIn, out uint attributesOut);
    [DllImport("shell32.dll")] private static extern int SHCreateShellItemArrayFromIDLists(uint count, [In] IntPtr[] ids, out IShellItemArray? items);
    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid folder, uint flags, IntPtr token, out IntPtr path);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, ref Input inputs, int size);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterClassExW", SetLastError = true)] private static extern ushort RegisterClassEx(ref WndClassEx cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateWindowExW", SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr window, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "DefWindowProcW")] private static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "GetMessageW")] private static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll", EntryPoint = "DispatchMessageW")] private static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleHandleW")] private static extern IntPtr GetModuleHandle(string? name);
}
