using Passthrough.Core.Shell;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>Every gate and connection test again, with the shells across the service's pipe (stage 4): a phone can't tell.</summary>
public sealed class ShellGateOverPipeTests() : ShellGateTests(overPipe: true)
{
    [Fact]
    public async Task WhenTheTrayAppGoesPhonesAreToldAndShellsSaySignedOutUntilItIsBack()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24}");
        var session = (await phone.Next(ShellEnvelope.Opened)).Session;
        await phone.Next(ShellEnvelope.Attached);

        CutTray();
        // As RECONCILIATION says: detached for what it had, an empty list, and the shells answer signed_out.
        Assert.Equal(session, (await phone.Next(ShellEnvelope.Detached)).Session);
        Assert.Empty((await phone.Next(ShellEnvelope.Sessions)).SessionList!);
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24,\"ref\":4}");
        var refused = await phone.Next(ShellEnvelope.Error);
        Assert.Equal("signed_out", refused.Reason);
        Assert.Equal(4, refused.Ref);
        await phone.Send("{\"t\":\"history\"}");
        Assert.Equal("signed_out", (await phone.Next(ShellEnvelope.Error)).Reason);
        // Closing an unknown session stays no_such_session.
        await phone.Send($"{{\"t\":\"close\",\"session\":\"{session}\"}}");
        Assert.Equal("no_such_session", (await phone.Next(ShellEnvelope.Error)).Reason);

        // The tray app comes back: the session it kept running is listed again, and can be attached.
        LinkTray();
        while ((await phone.Next(ShellEnvelope.Sessions)).SessionList!.Count == 0) { }
        await phone.Send($"{{\"t\":\"attach\",\"session\":\"{session}\",\"cols\":80,\"rows\":24}}");
        await phone.Next(ShellEnvelope.Attached);
    }

    [Fact]
    public async Task TranscriptsAndHistoryComeAcrossThePipe()
    {
        using var phone = await Proven();
        await phone.Send("{\"t\":\"open\",\"cols\":80,\"rows\":24}");
        var session = (await phone.Next(ShellEnvelope.Opened)).Session;
        await phone.Send("{\"t\":\"history\"}");
        Assert.Contains((await phone.Next(ShellEnvelope.HistoryList)).HistoryEntries!, e => e.Id == session);
        await phone.Send($"{{\"t\":\"transcript\",\"session\":\"{session!.ToLowerInvariant()}\"}}");
        var first = await phone.Next();
        Assert.NotNull(first);
        Assert.NotEqual(ShellEnvelope.Error, first!.T);
    }
}
