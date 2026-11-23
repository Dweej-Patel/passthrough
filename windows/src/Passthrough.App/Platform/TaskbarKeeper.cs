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

    public TaskbarKeeper(Action<string> log)
    {
        _log = log;
        _timer = new Timer(_ => Check(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    private void Check()
    {
        try
        {
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
