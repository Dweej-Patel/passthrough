using System.Runtime.InteropServices;

namespace Passthrough.App.Platform;

/// <summary>The few Win32 calls WinUI has no equivalent for: a message box with no window, the cursor position and a window's DPI.</summary>
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
}
