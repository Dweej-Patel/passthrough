using System.Text;
using Passthrough.Core.Shell.Sessions;
using Xunit;
using static Passthrough.Core.Shell.Sessions.ProgramStatus;

namespace Passthrough.Core.Tests.Shell;

/// <summary>Ports of ProgramStatusTests.swift's parser cases and SharedSessionTests.swift's terminal-report case.</summary>
public class ProgramStatusTests
{
    /// <summary>What Claude Code 2.1.325 sent in a recorded run: a permission prompt, a background agent, then done.</summary>
    private static readonly string[] Recorded =
    [
        "\u001b]7501;state=idle:app=claude-code\u0007",
        "\u001b]7501;state=working:app=claude-code\u0007",
        "\u001b]7501;state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiBjdXJsIC1zSSBodHRwczovL2V4YW1wbGUuY29tIC1vIC9kZXYvbnVsbA==\u0007",
        "\u001b]7501;state=working:app=claude-code\u0007",
        "\u001b]7501;state=working:app=claude-code:id=a98ef54decffe49b1:title=UnVuIHNsZWVwIGFuZCByZXBseSBwb25n\u0007",
        "\u001b]7501;state=clear:id=a98ef54decffe49b1\u0007",
        "\u001b]7501;state=done:app=claude-code\u0007",
        "\u001b]7501;state=clear\u0007",
    ];

    private static byte[] Report(string fields, string end = "\u0007") => Encoding.UTF8.GetBytes($"\u001b]7501;{fields}{end}");
    private static string B64(string text) => Convert.ToBase64String(Encoding.UTF8.GetBytes(text));

    private static string Text(ProgramStatus status)
    {
        if (status.CurrentSummary is not { } s) return "none";
        return string.Join(" | ", new[] { s.State, s.Kind, s.Message, s.Agents > 0 ? $"agents={s.Agents}" : null }.OfType<string>());
    }

    [Fact]
    public void ARecordedClaudeCodeRun()
    {
        var status = new ProgramStatus();
        var seen = new List<string>();
        foreach (var sequence in Recorded)
        {
            Assert.True(status.Scan(Encoding.UTF8.GetBytes(sequence)).HasFlag(Outcome.Changed), sequence);
            seen.Add(Text(status));
        }
        Assert.Equal(["idle", "working", "blocked | permission | approve Bash: curl -sI https://example.com -o /dev/null",
            "working", "working | agents=1", "working", "done", "none"], seen);
    }

    [Fact]
    public void TheQueryIsNoticedEitherWayItEnds()
    {
        var status = new ProgramStatus();
        Assert.Equal(Outcome.Queried, status.Scan("text\u001b]7501;?\u0007\u001b[c"u8));
        Assert.Equal(Outcome.Queried, status.Scan("\u001b]7501;?\u001b\\"u8));
        Assert.Null(status.CurrentSummary);
    }

    [Fact]
    public void ReportsSplitAcrossChunksAndAmongOtherOutput()
    {
        var status = new ProgramStatus();
        var whole = Encoding.UTF8.GetBytes($"\u001b]0;title\u0007\u001b[31mred\u001b]7501;state=working:msg={B64("Reading files")}\u001b\\more");
        foreach (var b in whole) status.Scan([b]);
        Assert.Equal("working | Reading files", Text(status));
    }

    [Fact]
    public void Agents()
    {
        var status = new ProgramStatus();
        status.Scan(Report("state=done"));
        status.Scan(Report($"state=working:id=a1:title={B64("Search the code")}"));
        Assert.Equal("working | agents=1", Text(status)); // not done while an agent works
        status.Scan(Report($"state=blocked:kind=permission:id=a1/b:title={B64("Run tests")}:msg={B64("approve Bash: swift test")}"));
        Assert.Equal("blocked | permission | Run tests: approve Bash: swift test | agents=2", Text(status));
        status.Scan(Report("state=clear:id=a1"));
        Assert.Equal("done", Text(status)); // clearing a record clears the ones beneath it
    }

    [Fact]
    public void MalformedReportsAreIgnored()
    {
        var status = new ProgramStatus();
        status.Scan(Report("state=working"));
        foreach (var bad in new[] { "state=sleeping", "kind=question", "state=done:msg=@@@", "state=done:id=bad id", "state=done:id=a//b",
                     $"state=done:msg={B64("two\nlines")}" })
            Assert.Equal(Outcome.None, status.Scan(Report(bad)));
        Assert.Equal("working", Text(status));
        Assert.Equal(Outcome.None, status.Scan(Encoding.UTF8.GetBytes("\u001b]7501;state=done:msg=" + new string('A', 5000) + "\u0007")));
        Assert.Equal("working", Text(status));
        Assert.Equal(Outcome.Changed, status.Scan(Report("state=blocked:kind=nonsense")));
        Assert.Equal("blocked", Text(status)); // an unknown kind is left out
    }

    [Fact]
    public void AFullResetAndAProgramGoneEndWhatItWasDoing()
    {
        var status = new ProgramStatus();
        status.Scan(Report("state=working"));
        Assert.Equal(Outcome.Changed, status.Scan("\u001bc"u8));
        Assert.Null(status.CurrentSummary);
        status.Scan(Report("state=blocked:kind=question"));
        status.Scan(Report("state=done:id=x"));
        Assert.True(status.ForgetAll());
        Assert.True(status.IsEmpty);
        Assert.False(status.ForgetAll());
    }

    [Fact]
    public void OtherTerminalsAnswersToTheQueryAreDropped()
    {
        Assert.Equal("abcd\u001b]11;rgb:0/0/0\u0007"u8.ToArray(),
            TerminalReports.RemovingProgramStatusReplies("ab\u001b]7501;?:states=idle,working\u001b\\cd\u001b]11;rgb:0/0/0\u0007"u8));
        Assert.Equal("plain"u8.ToArray(), TerminalReports.RemovingProgramStatusReplies("plain"u8));
    }

    [Fact]
    public void TerminalReportsAreToldFromTyping()
    {
        static string Kept(string text) => Encoding.UTF8.GetString(TerminalReports.Removing(Encoding.UTF8.GetBytes(text)));
        Assert.Equal("", Kept("\u001b[24;80R"));
        Assert.Equal("", Kept("\u001b[?1;2c\u001b[>0;276;0c\u001b[0n\u001b[?2004;1$y\u001b[?0u\u001b[8;24;80t"));
        Assert.Equal("", Kept("\u001b[I\u001b[O"));
        Assert.Equal("", Kept("\u001b]11;rgb:1e1e/1e1e/1e1e\u0007\u001b]10;rgb:ffff/ffff/ffff\u001b\\"));
        Assert.Equal("", Kept("\u001bP>|xterm(390)\u001b\\"));
        Assert.Equal("ab", Kept("a\u001b[3;1Rb"));
        foreach (var keys in new[] { "ls\r", "\u001b[A\u001b[B\u001b[C\u001b[D", "\u001bOP", "\u001b[3~", "\u001b[1;5C",
                     "\u001b[<0;10;5M\u001b[<0;10;5m", "\u001b[200~text\u001b[201~", "\u001b", "\u001bb", "\u001b[Z" })
            Assert.Equal(keys, Kept(keys));
        Assert.Equal("\u001b]11;rgb:1e1e", Kept("\u001b]11;rgb:1e1e"));
        Assert.Equal("\u001b[24;8", Kept("\u001b[24;8"));
    }

    [Fact]
    public void TheSupportReplyIsTheFixtures()
    {
        // The same answer the Mac writes (protocol/README.md, Program status).
        Assert.Equal("\u001b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u001b\\", Encoding.ASCII.GetString(SupportReply));
    }
}
