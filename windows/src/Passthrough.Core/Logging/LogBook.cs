using System.Globalization;
using System.Text;
using Passthrough.Core.Storage;

namespace Passthrough.Core.Logging;

/// <summary>
/// The app's log file: one stamped line per message, an exception with its type, HRESULT, stack and inner exceptions
/// (indented below its line). A message equal to the one before it (for an exception: the same type and message) is
/// counted instead of written, and the count is written before the next different line or on <see cref="Flush"/>.
/// Token-shaped text is redacted (<see cref="LogText.Redact"/>). When the file would pass <c>maxBytes</c> it is moved
/// to <c>&lt;file&gt;.1</c> (replacing the older one) and a new file is started. Thread-safe, and never throws: the log is
/// best effort, so a locked or full disk can't take the app down.
/// </summary>
public sealed class LogBook
{
    private readonly IFileSystem _files;
    private readonly TimeProvider _time;
    private readonly long _maxBytes;
    private readonly Lock _gate = new();
    private string? _lastKey;
    private int _repeats;

    public LogBook(IFileSystem files, string path, TimeProvider time, long maxBytes = 1_000_000)
    {
        _files = files;
        Path = path;
        _time = time;
        _maxBytes = maxBytes;
    }

    public string Path { get; }

    public void Info(string message) => Write("info ", OneLine(message), message, detail: null);

    public void Error(Exception e) =>
        Write("error", $"{e.GetType().Name}: {OneLine(e.Message)} (0x{e.HResult:X8})", $"{e.GetType().FullName}: {e.Message}", e.ToString());

    /// <summary>Writes the count of a message still being repeated (on quit).</summary>
    public void Flush()
    {
        lock (_gate)
        {
            if (_repeats == 0) return;
            Append(RepeatLine());
            _repeats = 0;
        }
    }

    private void Write(string level, string line, string key, string? detail)
    {
        key = level + key;
        lock (_gate)
        {
            if (key == _lastKey)
            {
                _repeats++;
                return;
            }
            var text = new StringBuilder();
            if (_repeats > 0) text.Append(RepeatLine());
            text.Append(Stamp()).Append(' ').Append(level).Append(' ').Append(line).Append(Environment.NewLine);
            if (detail is not null)
                foreach (var l in detail.Split('\n'))
                    text.Append("    ").Append(l.TrimEnd('\r')).Append(Environment.NewLine);
            Append(text.ToString());
            _lastKey = key;
            _repeats = 0;
        }
    }

    private string RepeatLine() =>
        $"{Stamp()} info  (the previous message repeated {_repeats} more {(_repeats == 1 ? "time" : "times")}){Environment.NewLine}";

    private void Append(string text)
    {
        text = LogText.Redact(text);
        try
        {
            if (System.IO.Path.GetDirectoryName(Path) is { Length: > 0 } dir) _files.CreateDirectory(dir);
            var size = _files.FileLength(Path);
            if (size > 0 && size + Encoding.UTF8.GetByteCount(text) > _maxBytes) _files.Move(Path, Path + ".1", overwrite: true);
            _files.AppendAllText(Path, text);
        }
        catch (Exception)
        {
            // Best effort: nothing to report a failing log to.
        }
    }

    private string Stamp() => _time.GetLocalNow().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    private static string OneLine(string s) => s.ReplaceLineEndings(" ");
}
