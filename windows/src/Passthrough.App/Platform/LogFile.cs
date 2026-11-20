namespace Passthrough.App.Platform;

/// <summary>
/// Appends to <c>%LOCALAPPDATA%\Passthrough\passthrough.log</c>. A message identical to the one before it is
/// counted, not repeated, and the count is written when something different arrives.
/// </summary>
internal static class LogFile
{
    private static readonly object Gate = new();
    private static string? _last;
    private static int _repeats;

    public static string Path { get; } = System.IO.Path.Combine(AppFolder.Path, "passthrough.log");

    public static void Error(Exception e) => Write($"{e.GetType().Name}: {e.Message}");

    public static void Write(string message)
    {
        lock (Gate)
        {
            if (message == _last)
            {
                _repeats++;
                return;
            }
            try
            {
                Directory.CreateDirectory(AppFolder.Path);
                var text = "";
                if (_repeats > 0) text += $"{Stamp()} (previous message repeated {_repeats} more times){Environment.NewLine}";
                text += $"{Stamp()} {message}{Environment.NewLine}";
                File.AppendAllText(Path, text);
            }
            catch (IOException)
            {
                // The log is best effort: a locked or full disk must not take the app down.
            }
            catch (UnauthorizedAccessException)
            {
            }
            _last = message;
            _repeats = 0;
        }
    }

    private static string Stamp() => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
}
