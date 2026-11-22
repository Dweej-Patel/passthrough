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
            if (!SetWindowPos(taskbar, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpNoOwnerZOrder)) return;
            if (_logged) return;
            _logged = true;
            _log("The taskbar had lost its place on top (a Remote Desktop resize); it was put back");
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
    }

    public void Dispose() => _timer.Dispose();

    private const int GwlExStyle = -20, WsExTopmost = 0x8;
    private const uint SwpNoSize = 0x1, SwpNoMove = 0x2, SwpNoActivate = 0x10, SwpNoOwnerZOrder = 0x200;
    private static readonly IntPtr HwndTopmost = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowW(string cls, string? name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
