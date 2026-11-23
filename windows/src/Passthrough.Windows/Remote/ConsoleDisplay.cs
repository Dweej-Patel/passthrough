using System.Runtime.InteropServices;
using System.Text.Json;
using Passthrough.Core.Shell;

namespace Passthrough.Windows.Remote;

/// <summary>
/// The PC's own primary monitor, for <c>host.display</c>: read only while this account's session is the one on the
/// PC's screen, since during a Remote Desktop view the session shows the phone's display instead. The last good
/// reading is kept, in memory and in <c>%LOCALAPPDATA%\Passthrough\display.json</c>, so a view started while the
/// session is remote still gets the monitor's values.
/// </summary>
public sealed class ConsoleDisplay(string file)
{
    private readonly Lock _lock = new();
    private HostDisplay? _last;
    private bool _loaded;

    public static ConsoleDisplay ForThisAccount() =>
        new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Passthrough", "display.json"));

    /// <summary>The monitor now when this session is on it, else the last reading (null: never read).</summary>
    public HostDisplay? Current()
    {
        lock (_lock)
        {
            if (!_loaded) { _last = Load(); _loaded = true; }
            if (ReadNow() is { } now && now != _last)
            {
                _last = now;
                Save(now);
            }
            return _last;
        }
    }

    private static HostDisplay? ReadNow()
    {
        try
        {
            if (GetSystemMetrics(SmRemoteSession) != 0) return null;
            if (!ProcessIdToSessionId((uint)Environment.ProcessId, out var session) || session != WTSGetActiveConsoleSessionId()) return null;
            // Physical pixels and the monitor's own DPI, whatever awareness the calling thread had.
            var previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
            try
            {
                var monitor = MonitorFromPoint(default, MonitorDefaultToPrimary);
                var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
                if (monitor == IntPtr.Zero || !GetMonitorInfoW(monitor, ref info)) return null;
                if (GetDpiForMonitor(monitor, 0, out var dpi, out _) != 0 || dpi == 0) return null;
                return new HostDisplay
                {
                    Width = info.Monitor.Right - info.Monitor.Left,
                    Height = info.Monitor.Bottom - info.Monitor.Top,
                    Scale = (int)Math.Round(dpi * 100.0 / 96),
                };
            }
            finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return null; }
    }

    private HostDisplay? Load()
    {
        try { return File.Exists(file) ? JsonSerializer.Deserialize<HostDisplay>(File.ReadAllText(file)) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private void Save(HostDisplay display)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, JsonSerializer.Serialize(display));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private const int SmRemoteSession = 0x1000, MonitorDefaultToPrimary = 1;
    private static readonly IntPtr PerMonitorAwareV2 = -4;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
}
