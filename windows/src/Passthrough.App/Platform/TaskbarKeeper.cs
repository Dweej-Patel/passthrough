using System.Runtime.InteropServices;

namespace Passthrough.App.Platform;

/// <summary>
/// Keeps Windows' taskbar above other windows in this session. When a Remote Desktop view resizes the session (a
/// phone turning, a new shape), Explorer lays the taskbar out at the new bottom edge but can lose its topmost flag,
/// so a window larger than the new desktop covers it and the person sees no taskbar. Every 2 seconds, if the taskbar
/// is shown but not topmost, it is put back on top: no window moves, nothing restarts, no setting changes.
/// </summary>
internal sealed class TaskbarKeeper : IDisposable
{
    private readonly Timer _timer;
    private readonly Action<string> _log;
    private bool _logged;
    private static int _fullScreen;

    /// <summary>
    /// A window of Passthrough's own (another computer's screen) went full screen, or left it. While one is, the
    /// taskbar is left where Windows put it: under the picture.
    /// </summary>
    public static void FullScreenBegan() => Interlocked.Increment(ref _fullScreen);
    public static void FullScreenEnded() => Interlocked.Decrement(ref _fullScreen);

    /// <summary>
    /// Tells Windows' shell that a window is (or is no longer) full screen, so the taskbar goes behind it at once
    /// (<c>ITaskbarList2::MarkFullscreenWindow</c>). Call on the window's own thread.
    /// </summary>
    public static void MarkFullScreen(IntPtr window, bool fullScreen)
    {
        try
        {
            var list = (ITaskbarList2)new TaskbarList();
            try
            {
                if (list.HrInit() == 0) list.MarkFullscreenWindow(window, fullScreen);
            }
            finally { Marshal.ReleaseComObject(list); }
        }
        catch (Exception e) when (e is COMException or InvalidCastException or UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Puts the taskbar that is on <paramref name="window"/>'s monitor directly behind that window, as Windows itself
    /// does for a full-screen window once it has noticed one. No window moves or changes size.
    /// </summary>
    public static void SendBehind(IntPtr window)
    {
        try
        {
            var monitor = MonitorFromWindow(window, MonitorDefaultToNearest);
            foreach (var taskbar in Taskbars().Where(t => MonitorFromWindow(t, MonitorDefaultToNearest) == monitor))
                SetWindowPos(taskbar, window, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpNoOwnerZOrder);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>Puts every taskbar back above other windows, where it always is.</summary>
    public static void BringBack()
    {
        try
        {
            foreach (var taskbar in Taskbars()) SetWindowPos(taskbar, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpNoOwnerZOrder);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>The taskbar, and the ones Windows shows on other monitors.</summary>
    private static List<IntPtr> Taskbars()
    {
        var found = new List<IntPtr>();
        if (FindWindowW("Shell_TrayWnd", null) is var main && main != IntPtr.Zero) found.Add(main);
        for (var next = FindWindowExW(IntPtr.Zero, IntPtr.Zero, "Shell_SecondaryTrayWnd", null); next != IntPtr.Zero && found.Count < 16;
             next = FindWindowExW(IntPtr.Zero, next, "Shell_SecondaryTrayWnd", null))
            found.Add(next);
        return found;
    }

    private const uint MonitorDefaultToNearest = 2;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string? name);

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    private class TaskbarList;

    [ComImport, Guid("602D4995-B13A-429b-A66E-1935E44F4317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList2
    {
        [PreserveSig] int HrInit();
        [PreserveSig] int AddTab(IntPtr window);
        [PreserveSig] int DeleteTab(IntPtr window);
        [PreserveSig] int ActivateTab(IntPtr window);
        [PreserveSig] int SetActiveAlt(IntPtr window);
        [PreserveSig] int MarkFullscreenWindow(IntPtr window, [MarshalAs(UnmanagedType.Bool)] bool fullScreen);
    }

    public TaskbarKeeper(Action<string> log)
    {
        _log = log;
        _timer = new Timer(_ => Check(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    private void Check()
    {
        try
        {
            if (Volatile.Read(ref _fullScreen) > 0) return;
            var taskbar = FindWindowW("Shell_TrayWnd", null);
            if (taskbar == IntPtr.Zero || !IsWindowVisible(taskbar)) return;
            if ((GetWindowLongW(taskbar, GwlExStyle) & WsExTopmost) != 0) return;
            // Windows takes the taskbar off the top on purpose for a full-screen window (a video, a game, a slideshow):
            // then it is left alone.
            if (FullScreenInFront(taskbar)) return;
            if (!SetWindowPos(taskbar, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpNoOwnerZOrder)) return;
            if (_logged) return;
            _logged = true;
            _log("The taskbar had lost its place on top (a Remote Desktop resize); it was put back");
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>The window in front covers the whole of the taskbar's monitor.</summary>
    private static bool FullScreenInFront(IntPtr taskbar)
    {
        var front = GetForegroundWindow();
        if (front == IntPtr.Zero || front == taskbar || !GetWindowRect(front, out var window)) return false;
        // A window with a title bar isn't full screen, however large: after a Remote Desktop resize, windows laid out for
        // the bigger desktop cover the smaller one, and those are exactly the ones the taskbar must stay above.
        if ((GetWindowLongW(front, GwlStyle) & WsCaption) == WsCaption) return false;
        // Nor is the desktop itself, which covers the monitor when it has the focus.
        if (front == GetShellWindow() || ClassOf(front) is "Progman" or "WorkerW") return false;
        var monitor = MonitorFromWindow(taskbar, MonitorDefaultToPrimary);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info)) return false;
        var screen = info.Monitor;
        return window.Left <= screen.Left && window.Top <= screen.Top && window.Right >= screen.Right && window.Bottom >= screen.Bottom;
    }

    public void Dispose() => _timer.Dispose();

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    private const uint MonitorDefaultToPrimary = 1;
    private static string ClassOf(IntPtr window)
    {
        var name = new char[64];
        var length = GetClassNameW(window, name, name.Length);
        return length > 0 ? new string(name, 0, length) : "";
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, char[] name, int max);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);

    private const int GwlExStyle = -20, WsExTopmost = 0x8, GwlStyle = -16, WsCaption = 0x00C00000;
    private const uint SwpNoSize = 0x1, SwpNoMove = 0x2, SwpNoActivate = 0x10, SwpNoOwnerZOrder = 0x200;
    private static readonly IntPtr HwndTopmost = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowW(string cls, string? name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
