using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Passthrough.Windows.ClipSync;

// Opens an Explorer window on an empty temp folder, drags a temp file (and a folder) into it with the product's
// DropPerformer, and says whether they arrived. It takes the pointer for about a second.
// Usage: ClipDropProbe [explorer|titlebar]
var mode = args.Length > 0 ? args[0] : "explorer";
var root = Path.Combine(Path.GetTempPath(), "pt-drop-" + Guid.NewGuid().ToString("N")[..8]);
var source = Path.Combine(root, "source");
var target = Path.Combine(root, "PassthroughDropTarget" + Guid.NewGuid().ToString("N")[..6]);
Directory.CreateDirectory(Path.Combine(source, "Dropped folder", "Inner"));
Directory.CreateDirectory(target);
File.WriteAllText(Path.Combine(source, "dropped.txt"), "dropped by the probe");
File.WriteAllText(Path.Combine(source, "Dropped folder", "Inner", "deep.txt"), "deep");
var paths = new[] { Path.Combine(source, "dropped.txt"), Path.Combine(source, "Dropped folder") };

Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
IntPtr window = IntPtr.Zero;
try
{
    Process.Start(new ProcessStartInfo("explorer.exe", $"\"{target}\"") { UseShellExecute = false })?.Dispose();
    var name = Path.GetFileName(target);
    var waited = Stopwatch.StartNew();
    while (window == IntPtr.Zero && waited.Elapsed < TimeSpan.FromSeconds(10))
    {
        Thread.Sleep(200);
        Native.EnumWindows((h, _) =>
        {
            var title = new StringBuilder(512);
            Native.GetWindowText(h, title, title.Capacity);
            if (!title.ToString().Contains(name, StringComparison.OrdinalIgnoreCase) || !Native.IsWindowVisible(h)) return true;
            window = h;
            return false;
        }, IntPtr.Zero);
    }
    if (window == IntPtr.Zero) { Console.WriteLine("FAIL: the Explorer window didn't open"); return; }
    Thread.Sleep(1200); // let it draw
    Native.SetForegroundWindow(window);
    Thread.Sleep(300);
    Native.GetWindowRect(window, out var rect);
    var x = rect.Left + (rect.Right - rect.Left) * 6 / 10;
    // "titlebar": a place in the same window that takes no files.
    var y = mode == "titlebar" ? rect.Top + 14 : rect.Top + (rect.Bottom - rect.Top) * 6 / 10;
    var at = DropPerformer.At(x, y);
    Console.WriteLine($"window {window:X} at ({rect.Left},{rect.Top})-({rect.Right},{rect.Bottom}); point ({x},{y}) is over {at?.Window:X} (pid {at?.Process})");
    if (at?.Window != window) { Console.WriteLine("FAIL: something else is over the Explorer window; not dragging"); return; }
    var clock = Stopwatch.StartNew();
    // As the product does: only on the window that is there now.
    var outcome = DropPerformer.Drop(paths, x, y, TimeSpan.FromSeconds(8), Console.WriteLine, expected: at);
    Console.WriteLine($"outcome: {outcome} after {clock.ElapsedMilliseconds} ms");
    var arrived = false;
    for (var i = 0; i < 30 && !arrived; i++)
    {
        Thread.Sleep(100);
        arrived = File.Exists(Path.Combine(target, "dropped.txt")) && File.Exists(Path.Combine(target, "Dropped folder", "Inner", "deep.txt"));
    }
    Console.WriteLine(arrived && outcome == DropOutcome.Dropped ? "PASS: the file and the folder are in the target folder" : "FAIL: " + string.Join(", ", Directory.GetFileSystemEntries(target).Select(Path.GetFileName)));
    Console.WriteLine($"the sources are still there (copy, not move): {File.Exists(paths[0]) && Directory.Exists(paths[1])}");
}
finally
{
    if (window != IntPtr.Zero) Native.PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    Thread.Sleep(500);
    try { Directory.Delete(root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
}

internal static class Native
{
    public delegate bool EnumProc(IntPtr window, IntPtr param);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextW")] public static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
}
