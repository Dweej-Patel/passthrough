using Passthrough.Core.Presentation;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public sealed class RemoteSummaryTests
{
    private static RemoteDevice D(string name, int connections = 0, bool viewing = false, int shells = 0, bool computer = false) =>
        new(name.ToLowerInvariant(), name, computer, connections, viewing, shells);

    [Fact]
    public void OnlyWhatIsOnThisPcIsListedViewersFirst()
    {
        var here = RemoteSummary.Here([D("iPad"), D("iPhone", connections: 1, shells: 2), D("MacBook", connections: 1, viewing: true, computer: true), D("Pixel", shells: 1)]);
        Assert.Equal(["MacBook", "iPhone", "Pixel"], here.Select(h => h.Name));
        Assert.Equal("Viewing the screen", here[0].Detail);
        // A computer whose clipboard is synced while it views says so; syncing without a view is never said.
        Assert.Equal("Viewing the screen · syncing the clipboard · 1 shell open",
            RemoteSummary.Here([new RemoteDevice("c", "MacBook", true, 2, true, 1, Syncing: true)])[0].Detail);
        Assert.Equal("Connected", RemoteSummary.Here([new RemoteDevice("c", "MacBook", true, 1, false, 0, Syncing: true)])[0].Detail);
        Assert.Equal("2 shells open", here[1].Detail);
        Assert.Equal("1 shell open", here[2].Detail);
        Assert.Equal("Connected", RemoteSummary.Here([D("iPhone", connections: 1)])[0].Detail);
    }

    [Fact]
    public void TheHeaderFollowsRemoteAccessNotTheCable()
    {
        Assert.Null(RemoteSummary.Header(RemoteMode.NeedsSetup, null, 0, []));
        Assert.Equal("Remote access is off", RemoteSummary.Header(RemoteMode.Off, null, 2, [])!.Title);
        var broken = RemoteSummary.Header(RemoteMode.Unavailable, "Remote access isn't running.", 1, [])!;
        Assert.Equal(("Remote access needs a look", "Remote access isn't running.", RemoteTone.Attention), (broken.Title, broken.Subtitle, broken.Tone));
        Assert.Equal(("This PC is reachable", "2 phones can reach it"), Pair(RemoteSummary.Header(RemoteMode.On, null, 2, [])!));
        Assert.Equal("Plug a paired phone in once to give it access", RemoteSummary.Header(RemoteMode.On, null, 0, [])!.Subtitle);
    }

    [Fact]
    public void AViewerComesFirstThenShells()
    {
        var both = RemoteSummary.Here([D("iPhone", connections: 2, shells: 2), D("MacBook", connections: 1, viewing: true)]);
        Assert.Equal("This PC's screen is in use", RemoteSummary.Header(RemoteMode.On, null, 1, both)!.Title);
        Assert.Equal("Turn on…", RemoteSummary.HeaderAction(RemoteMode.Off));
        Assert.Equal("Fix…", RemoteSummary.HeaderAction(RemoteMode.Unavailable));
        Assert.Null(RemoteSummary.HeaderAction(RemoteMode.On));
        Assert.Equal("This PC · Pair", RemoteSummary.ThisPcTabTitle(true));
        var shells = RemoteSummary.Here([D("iPhone", connections: 1, shells: 2)]);
        Assert.Equal("iPhone has 2 shells open", RemoteSummary.Header(RemoteMode.On, null, 1, shells)!.Title);
        var two = RemoteSummary.Here([D("iPhone", shells: 1), D("Pixel", shells: 2)]);
        Assert.Equal(("3 shells open on this PC", "From 2 devices"), Pair(RemoteSummary.Header(RemoteMode.On, null, 2, two)!));
        Assert.Equal("Remote · 2", RemoteSummary.TabTitle(two));
        Assert.Equal("Remote", RemoteSummary.TabTitle([]));
    }

    [Fact]
    public void TheReachLineAndQuitQuestion()
    {
        Assert.Equal("2 phones and 1 computer can reach this PC", RemoteSummary.ReachLine(RemoteMode.On, 2, 1));
        Assert.Equal("1 phone can reach this PC", RemoteSummary.ReachLine(RemoteMode.On, 1, 0));
        Assert.Equal("No phone can reach this PC yet", RemoteSummary.ReachLine(RemoteMode.On, 0, 0));
        Assert.StartsWith("Turn on Remote access", RemoteSummary.ReachLine(RemoteMode.Off, 3, 0));

        Assert.Null(RemoteSummary.QuitQuestion(enabled: false, shells: 0));
        Assert.Equal("1 shell a phone opened ends.", RemoteSummary.QuitQuestion(enabled: false, shells: 1));
        Assert.Equal("2 shells phones opened end. This PC's screen stays reachable from your phones until you turn Remote access off.",
            RemoteSummary.QuitQuestion(enabled: true, shells: 2));
    }

    private static (string, string) Pair(RemoteHeader h) => (h.Title, h.Subtitle);
}
