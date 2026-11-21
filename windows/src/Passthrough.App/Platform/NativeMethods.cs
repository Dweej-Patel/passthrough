using System.Runtime.InteropServices;

namespace Passthrough.App.Platform;

/// <summary>The few Win32 calls WinUI has no equivalent for: a message box with no window, the cursor position, a window's DPI and bringing a window to the front.</summary>
internal static class NativeMethods
{
    private const uint MbOk = 0x0;
    private const uint MbIconError = 0x10;
    private const uint MbSetForeground = 0x10000;

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    /// <summary>A modal error box that needs no window (used when startup failed and there may be none).</summary>
    public static void ShowError(string text, string caption) => MessageBoxW(IntPtr.Zero, text, caption, MbOk | MbIconError | MbSetForeground);

    /// <summary>Where the cursor is, in physical pixels; (0, 0) if Windows won't say.</summary>
    public static Point CursorPosition() => GetCursorPos(out var p) ? p : default;

    /// <summary>The DPI of the monitor the window is on (the process is PerMonitorV2); 0 when it can't be read.</summary>
    public static uint DpiOf(IntPtr hwnd) => GetDpiForWindow(hwnd);

    /// <summary>
    /// Makes the window the one the user is typing into. Windows refuses that to a process that isn't in front already,
    /// which a tray app never is, and would leave the window behind the others; joining the front window's input queue
    /// for the call is the way round it. A front window that isn't answering is left alone (joining its queue would
    /// wait on it), and Windows refuses the join for an elevated one. False when the window did not get to the front.
    /// </summary>
    public static bool BringToFront(IntPtr hwnd)
    {
        if (SetForegroundWindow(hwnd)) return GetForegroundWindow() == hwnd;
        var frontWindow = GetForegroundWindow();
        var front = GetWindowThreadProcessId(frontWindow, out _);
        var mine = GetCurrentThreadId();
        if (front == 0 || front == mine || IsHungAppWindow(frontWindow) || !AttachThreadInput(mine, front, true)) return false;
        try { SetForegroundWindow(hwnd); }
        finally { AttachThreadInput(mine, front, false); }
        return GetForegroundWindow() == hwnd;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsHungAppWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, [MarshalAs(UnmanagedType.Bool)] bool on);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    /// <summary>The side of a small icon (the notification area's, a title bar's) in pixels at the system's scale; 16 if Windows won't say.</summary>
    public static int SmallIconSize() => GetSystemMetrics(SmCxSmIcon) is > 0 and var size ? size : 16;

    private const int SmCxSmIcon = 49;

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
