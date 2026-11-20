namespace Passthrough.App.Platform;

/// <summary><c>%LOCALAPPDATA%\Passthrough</c>, where settings, secrets and the log live.</summary>
internal static class AppFolder
{
    public static string Path { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Passthrough");
}
