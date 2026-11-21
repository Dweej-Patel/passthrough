using Passthrough.Core.Logging;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Logging;

public class LogBookTests
{
    private const string Path = "/app/passthrough.log";
    private const string Token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"; // 43 URL-safe base64 characters

    private readonly MemoryFileSystem _fs = new();
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 11, 20, 9, 30, 5, TimeSpan.Zero));

    private string[] Lines => _fs.Files.TryGetValue(Path, out var text) ? text.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries) : [];

    [Fact]
    public void Info_IsOneStampedLine()
    {
        var log = new LogBook(_fs, Path, _time);
        log.Info("usbmux watcher: Watching");
        Assert.Equal(["2026-11-20 09:30:05 info  usbmux watcher: Watching"], Lines);
        Assert.Equal(Path, log.Path);
    }

    [Fact]
    public void Error_CarriesTheTypeMessageHResultStackAndInnerException()
    {
        var log = new LogBook(_fs, Path, _time);
        Exception thrown;
        try { Throw(); throw new InvalidOperationException(); }
        catch (Exception e) { thrown = e; }

        log.Error(thrown);

        var lines = Lines;
        Assert.Equal($"2026-11-20 09:30:05 error InvalidOperationException: outer (0x{thrown.HResult:X8})", lines[0]);
        Assert.Contains(lines, l => l.StartsWith("    ") && l.Contains("Throw")); // the stack, indented
        Assert.Contains(lines, l => l.Contains("IOException: inner"));       // the inner exception
        static void Throw()
        {
            try { throw new IOException("inner"); }
            catch (IOException e) { throw new InvalidOperationException("outer", e); }
        }
    }

    [Fact]
    public void Repeats_AreCounted_NotWritten_AndTheCountComesBeforeTheNextLine()
    {
        var log = new LogBook(_fs, Path, _time);
        log.Info("adb:R58 (Android phone): channel closed: AppNotRunning; retrying");
        log.Info("adb:R58 (Android phone): channel closed: AppNotRunning; retrying");
        log.Info("adb:R58 (Android phone): channel closed: AppNotRunning; retrying");
        log.Error(new IOException("locked"));
        log.Error(new IOException("locked")); // the same type and message: a repeat, even with another stack
        log.Info("next");

        Assert.Equal([
            "2026-11-20 09:30:05 info  adb:R58 (Android phone): channel closed: AppNotRunning; retrying",
            "2026-11-20 09:30:05 info  (the previous message repeated 2 more times)",
            "2026-11-20 09:30:05 error IOException: locked (0x80131620)",
            "2026-11-20 09:30:05 info  (the previous message repeated 1 more time)",
            "2026-11-20 09:30:05 info  next",
        ], Lines.Where(l => !l.StartsWith("    ")));
    }

    [Fact]
    public void Flush_WritesAPendingRepeatCount()
    {
        var log = new LogBook(_fs, Path, _time);
        log.Info("a");
        log.Info("a");
        log.Flush();
        log.Flush();
        Assert.Equal(["2026-11-20 09:30:05 info  a", "2026-11-20 09:30:05 info  (the previous message repeated 1 more time)"], Lines);
    }

    [Fact]
    public void ATokenShapedRun_IsNeverWritten()
    {
        var log = new LogBook(_fs, Path, _time);
        log.Info($"paired with {Token}.");
        log.Error(new InvalidOperationException($"bad token \"{Token}\""));
        Assert.DoesNotContain(Token, _fs.Files[Path]);
        Assert.Contains("paired with (redacted).", _fs.Files[Path]);
    }

    [Fact]
    public void AFullFile_IsMovedAsideToDotOne_AndANewOneStarted()
    {
        var log = new LogBook(_fs, Path, _time, maxBytes: 150);
        log.Info(new string('a', 60));
        log.Info(new string('b', 60)); // would pass 150 bytes
        log.Info(new string('c', 10));

        Assert.Contains(new string('a', 60), _fs.Files[Path + ".1"]);
        Assert.DoesNotContain("aaa", _fs.Files[Path]);
        Assert.Contains(new string('b', 60), _fs.Files[Path]);
        Assert.Contains(new string('c', 10), _fs.Files[Path]);
    }

    [Fact]
    public void ADiskThatFails_NeverThrows()
    {
        _fs.Fail = (_, _) => new IOException("disk full");
        var log = new LogBook(_fs, Path, _time);
        log.Info("x");
        log.Error(new IOException("y"));
        log.Flush();
        Assert.Empty(Lines);
    }

    [Fact]
    public void LogText_Redact_OnlyTouchesExactly43CharacterRuns()
    {
        Assert.Equal("t=(redacted);", LogText.Redact($"t={Token};"));
        Assert.Equal(Token + "x", LogText.Redact(Token + "x"));               // 44 characters: not a token
        Assert.Equal("0123456789abcdef", LogText.Redact("0123456789abcdef"));
        Assert.Equal("at Passthrough.Core.Session.HostSession.OpenClient()", LogText.Redact("at Passthrough.Core.Session.HostSession.OpenClient()"));
    }
}
