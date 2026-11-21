using Passthrough.Core.Logging;
using Passthrough.Core.Storage;

namespace Passthrough.App.Platform;

/// <summary>
/// <c>%LOCALAPPDATA%\Passthrough\passthrough.log</c>, written by Core's <see cref="LogBook"/> (formatting, repeat counting,
/// redaction and the 1 MB roll-over are there, with tests). Safe from any thread; never throws.
/// </summary>
internal static class LogFile
{
    private static readonly LogBook Book = new(PhysicalFileSystem.Instance, System.IO.Path.Combine(AppFolder.Path, "passthrough.log"), TimeProvider.System);

    public static string Path => Book.Path;

    public static void Write(string message) => Book.Info(message);

    public static void Error(Exception e) => Book.Error(e);

    public static void Flush() => Book.Flush();
}
