using System.Runtime.InteropServices;

namespace Passthrough.App.Platform;

/// <summary>The few Win32 calls WinUI has no equivalent for: a message box with no window, and the cursor's monitor and DPI.</summary>
internal static class NativeMethods
{
    private const uint MbOk = 0x0;
    private const uint MbIconError = 0x10;
    private const uint MbSetForeground = 0x10000;
    private const uint MonitorDefaultToNearest = 2;
    private const int MdtEffectiveDpi = 0;

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

    /// <summary>The effective DPI of the monitor nearest <paramref name="p"/>; 0 when it can't be read.</summary>
    public static uint DpiAt(Point p)
    {
        var monitor = MonitorFromPoint(p, MonitorDefaultToNearest);
        if (monitor == IntPtr.Zero) return 0;
        return GetDpiForMonitor(monitor, MdtEffectiveDpi, out var dpiX, out _) == 0 ? dpiX : 0;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(Point point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);
}
