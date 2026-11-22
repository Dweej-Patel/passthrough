using Passthrough.Core.Pipe;
using Xunit;

namespace Passthrough.Core.Tests.Pipe;

public sealed class NoticeBoardTests
{
    private static readonly DateTimeOffset At = new(2026, 11, 21, 14, 2, 0, TimeSpan.Zero);
    private static string Clock(DateTimeOffset t) => t.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    [Fact]
    public void AViewIsTheNoticeThePlanWrites()
    {
        var board = new NoticeBoard();
        board.Viewed("A", "phone", "iPhone", At, At.AddMinutes(18), Clock);
        Assert.Equal("iPhone used this PC's screen, 14:02 to 14:20. Your windows may have moved.", board.For("A").Single().Text);
        Assert.Empty(board.For("B")); // another account never sees it
    }

    [Fact]
    public void ViewsCloseTogetherAreOneAndShortOnesNone()
    {
        var board = new NoticeBoard();
        board.Viewed("A", "phone", "iPhone", At, At.AddSeconds(5), Clock);
        Assert.Empty(board.For("A"));
        board.Viewed("A", "phone", "iPhone", At, At.AddMinutes(1), Clock);
        board.Viewed("A", "phone", "iPhone", At.AddMinutes(3), At.AddMinutes(10), Clock);
        Assert.Equal("iPhone used this PC's screen, 14:02 to 14:12. Your windows may have moved.", board.For("A").Single().Text);
    }

    [Fact]
    public void AnsweredGoesAndExposureFollowsTheCheck()
    {
        var board = new NoticeBoard();
        board.Add("A", PipeNotice.Granted, "x", "phone");
        Assert.True(board.Answer("A", board.For("A").Single().Id));
        Assert.Empty(board.For("A"));
        board.Exposed(["A", "B"], "Windows Firewall is off for a network profile.");
        Assert.Single(board.For("B"));
        Assert.False(board.Answer("A", "exposed")); // it goes only when Remote Desktop is closed again
        board.Exposed(["A", "B"], null);
        Assert.Empty(board.For("A"));
    }

    [Fact]
    public void AtMostTwentyAnAccount()
    {
        var board = new NoticeBoard();
        for (var i = 0; i < 25; i++) board.Add("A", PipeNotice.Granted, $"n{i}");
        Assert.Equal(NoticeBoard.PerAccount, board.For("A").Count);
        Assert.Equal("n5", board.For("A")[0].Text);
    }
}
