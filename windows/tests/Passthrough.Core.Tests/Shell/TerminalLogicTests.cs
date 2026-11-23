using System.Text;
using Passthrough.Core.Shell.Sessions;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>Ports of TerminalModesTests.swift (without the PTY cases) and ShellQuestionTests.swift.</summary>
public class TerminalLogicTests
{
    private static TerminalModes Modes(string text) => new TerminalModes().Scanned(Encoding.UTF8.GetBytes(text));
    private static string Restoring(string text) => Encoding.UTF8.GetString(Modes(text).Restoring());
    private static string? Find(string text) => ShellQuestion.Find(Encoding.UTF8.GetBytes(text));

    [Fact]
    public void NothingOnRestoresNothing()
    {
        Assert.Equal("", Restoring("hello\r\n\u001b[31mred\u001b[0m \u001b[2J\u001b[H"));
        Assert.Equal("", Restoring("\u001b[?25l\u001b[?25h\u001b[?2004h\u001b[?2004l"));
    }

    [Fact]
    public void AFullScreenProgramsModes()
    {
        var start = "\u001b[?2004h\u001b[?1004h\u001b[>5u\u001b[?1049h\u001b[<u\u001b[>5u"
            + "\u001b[?1000h\u001b[?1002h\u001b[?1003h\u001b[?1006h\u001b[>4;2m\u001b[?25l";
        Assert.True(Modes(start).IsAlternateScreen);
        Assert.Equal("\u001b[=0;1u\u001b[>5u" + "\u001b[?1049h" + "\u001b[=0;1u\u001b[>5u"
            + "\u001b[?25l\u001b[?1004h\u001b[?2004h" + "\u001b[?1003h\u001b[?1006h\u001b[>4;2m", Restoring(start));
    }

    [Fact]
    public void LeavingTheAlternateScreenAndTurningTheMouseOff()
    {
        Assert.Equal("", Restoring("\u001b[?1049h\u001b[?1002h\u001b[?1000l\u001b[?1049l"));
        Assert.Equal("\u001b[?1049h", Restoring("\u001b[?1049h\u001b[?1006h\u001b[?1006l"));
        Assert.Equal("\u001b[?1049h\u001b[?1h\u001b=", Restoring("\u001b[?1;1049h\u001b="));
    }

    [Fact]
    public void ResetsAndTheKeyboardStack()
    {
        Assert.Equal("", Restoring("\u001b[?1049h\u001b[?2004h\u001b[>1u\u001bc"));
        Assert.Equal("\u001b[?1049h", Restoring("\u001b[?1049h\u001b[?1h\u001b[?25l\u001b=\u001b[!p"));
        Assert.Equal("", Restoring("\u001b[?66h\u001b[!p"));
        Assert.Equal("\u001b[=0;1u\u001b[>1u", Restoring("\u001b[>1u\u001b[>3u\u001b[<u"));
        Assert.Equal("", Restoring("\u001b[>1u\u001b[<5u"));
        Assert.Equal("\u001b[=1;1u", Restoring("\u001b[=8;1u\u001b[=1;2u\u001b[=8;3u"));
    }

    [Fact]
    public void SplitSequences_Strings_AndOverlongParameters()
    {
        var split = new TerminalModes();
        split.Scan("\u001b[?10"u8);
        split.Scan("49h"u8);
        Assert.True(split.IsAlternateScreen);
        Assert.Equal("", Restoring("\u001b]0;title?1049h\u0007\u001b[38;5;1m"));
        Assert.Equal("", Restoring("\u001b[?" + string.Concat(Enumerable.Repeat("1;", 100)) + "1049h"));
        Assert.Equal("\u001b[?1049h", Restoring("\u001bPtmux;\u001b\u001b[?1049h\u001b\\"));
        Assert.Equal("\u001b[?2004h", Restoring("\u001b]0;unterminated title\u001b[?2004h"));
        Assert.Equal("", Restoring("\u001b]0;?1049h\u0007"));
    }

    [Fact]
    public void ReplaysMatchReadingEverythingFromTheStart()
    {
        var random = new Random(7501);
        string[] pieces = ["text ", "\r\n", "\u001b[?1049h", "\u001b[?1049l", "\u001b[?2004h", "\u001b[?2004l",
            "\u001b[>5u", "\u001b[<u", "\u001b[?1002h", "\u001b[?1000l", "\u001b[31m", "é"];
        foreach (var capacity in new[] { 16, 40, 100 })
        {
            var buffer = new ScrollbackBuffer(capacity);
            var all = new List<byte>();
            for (int n = 0; n < 400; n++)
            {
                var chunk = string.Concat(Enumerable.Range(0, random.Next(1, 5)).Select(_ => pieces[random.Next(pieces.Length)]));
                var data = Encoding.UTF8.GetBytes(chunk);
                if (data.Length > 2 && random.Next(2) == 1)
                {
                    var cut = random.Next(1, data.Length);
                    buffer.Append(data.AsSpan(0, cut)); all.AddRange(data[..cut]); data = data[cut..];
                }
                buffer.Append(data); all.AddRange(data);
                if (!buffer.IsPartial) continue;
                var contentsStart = all.Count - capacity;
                var window = all.Skip(contentsStart).Take(ScrollbackBuffer.ResyncWindow).ToList();
                var nl = window.IndexOf(0x0A);
                var from = contentsStart;
                if (nl >= 0) from = contentsStart + nl + 1;
                else while (from < all.Count && (all[from] & 0xC0) == 0x80) from++;
                var expected = new TerminalModes().Scanned(all.Take(from).ToArray()).Restoring().Concat(all.Skip(from)).ToArray();
                Assert.Equal(expected, buffer.Replay());
            }
        }
    }

    [Fact]
    public void AReplayFromTheStartIsUnchanged_AndAPartialOneTurnsOnWhatWasCutOff()
    {
        var whole = new ScrollbackBuffer(64);
        whole.Append("\u001b[?1049hframe\n"u8);
        Assert.False(whole.IsPartial);
        Assert.Equal("\u001b[?1049hframe\n"u8.ToArray(), whole.Replay());

        var buffer = new ScrollbackBuffer(32);
        buffer.Append("$ claude\r\n\u001b[?1049h\u001b[?1002h\u001b[?1006h"u8);
        for (int n = 0; n < 20; n++) buffer.Append(Encoding.UTF8.GetBytes($"\u001b[H frame {n}\n"));
        Assert.True(buffer.IsPartial);
        Assert.True(buffer.Modes.IsAlternateScreen);
        var replay = Encoding.UTF8.GetString(buffer.Replay());
        Assert.StartsWith("\u001b[?1049h\u001b[?1002h\u001b[?1006h", replay);
        Assert.EndsWith("frame 19\n", replay);
        Assert.DoesNotContain("claude", replay);
    }

    [Fact]
    public void ModesInTheSkippedStartOfTheTailCount()
    {
        var buffer = new ScrollbackBuffer(16);
        buffer.Append(Encoding.UTF8.GetBytes(new string('x', 30)));
        buffer.Append("ab\u001b[?2004hcd\nlast"u8);
        Assert.Equal("\u001b[?2004hlast", Encoding.UTF8.GetString(buffer.Replay()));
        buffer.Append("\u001b[?2004l"u8);
        Assert.Equal("\u001b[?2004hlast\u001b[?2004l", Encoding.UTF8.GetString(buffer.Replay()));
    }

    [Fact]
    public void Question_APromptAboveItsChoices()
    {
        const string esc = "\u001b[";
        var screen = $"{esc}2J{esc}H{esc}38;5;174m╭────────────╮{esc}0m{esc}2;1H│ Edit file {esc}1mHomeView.swift{esc}0m │"
            + $"{esc}4;1H Do you want to make this edit to HomeView.swift?"
            + $"{esc}5;1H{esc}36m❯ 1. Yes{esc}0m{esc}6;1H  2. Yes, and don't ask again this session"
            + $"{esc}7;1H  3. No, and tell Claude what to do differently (esc){esc}8;1H\u001b]0;claude\u0007";
        Assert.Equal("Do you want to make this edit to HomeView.swift?", Find(screen));
    }

    [Fact]
    public void Question_ChoicesPasswordsAndOrdinaryOutput()
    {
        Assert.Equal("Proceed? [y/N]", Find("Removing 3 files\r\nProceed? [y/N] "));
        Assert.Equal("Overwrite config (y/n)", Find("Overwrite config (y/n)"));
        Assert.Equal("Password:", Find("$ sudo pmset -g\r\nPassword:"));
        Assert.Equal("[sudo] password for dev:", Find("[sudo] password for dev: "));
        Assert.Null(Find("$ ls\r\nREADME.md  Package.swift\r\n$ "));
        Assert.Null(Find("build finished in 34s\r\n"));
        Assert.Null(Find("?\r\n"));
        Assert.Null(Find("GET /search?q=x\r\n"));
        Assert.Null(Find(""));
        Assert.Null(Find(string.Join("\r\n", new[] { "Continue with the update?" }.Concat(Enumerable.Range(1, 20).Select(i => $"compiling module {i}")))));
        var found = Find("Do you want to " + string.Concat(Enumerable.Repeat("really ", 30)) + "continue?")!;
        Assert.Equal(ShellQuestion.MaxLength, found.Length);
        Assert.EndsWith("…", found);
    }
}
