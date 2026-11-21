namespace Passthrough.App.Platform;

/// <summary>
/// The app's icon, the same art as the Mac and phone apps (scaled from the Mac's AppIcon, icon-1024.png). One
/// file with every size from 16 to 256 pixels, used for the exe, the tray and the windows.
/// </summary>
internal static class AppIcon
{
    public static string Path { get; } = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
}
