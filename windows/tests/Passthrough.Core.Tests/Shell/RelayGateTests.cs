using Passthrough.Core.Screen;
using Passthrough.Core.Shell;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>The <c>rdp</c> request on a phone's connection (stage 5): the refusals in RECONCILIATION's order, then the splice.</summary>
public sealed class RelayGateTests() : ShellGateTests(overPipe: false)
{
    [Fact]
    public async Task APhoneWithScreenGetsTheCertificateThenRemoteDesktopsBytesUnderNla()
    {
        AllowScreen();
        Desktop.Verdict = RelayVerdict.Ready(3389);
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        var ready = await phone.Next(ShellEnvelope.RdpReady);
        Assert.Equal(new string('a', 64), ready.CertSHA256);
        await phone.Raw.WriteAsync(global::Passthrough.Core.Tests.Screen.ScreenTests.Request(0x0B));
        var confirm = new byte[19];
        await phone.Raw.ReadExactlyAsync(confirm).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(global::Passthrough.Core.Tests.Screen.ScreenTests.Confirm(2), confirm);
        await phone.Raw.WriteAsync("hello desktop"u8.ToArray());
        var echo = new byte[13];
        await phone.Raw.ReadExactlyAsync(echo).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal("hello desktop"u8.ToArray(), echo);
    }

    [Fact]
    public async Task ARemoteDesktopThatSkipsNlaIsClosed()
    {
        AllowScreen();
        Desktop.Verdict = RelayVerdict.Ready(3389);
        Desktop.Selected = 1; // TLS only: Windows' logon screen, unlimited tries
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        await phone.Next(ShellEnvelope.RdpReady);
        await phone.Raw.WriteAsync(global::Passthrough.Core.Tests.Screen.ScreenTests.Request(0x0B));
        var buffer = new byte[19];
        Assert.Equal(0, await phone.Raw.ReadAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(10)));
    }

    [Fact]
    public async Task WithoutScreenItIsScreenNotAllowed()
    {
        Desktop.Verdict = RelayVerdict.Ready(3389);
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        Assert.Equal("screen_not_allowed", (await phone.Next(ShellEnvelope.Error)).Reason);
        Assert.Equal(0, Desktop.Dials);
    }

    [Fact]
    public async Task WhatIsntRemoteDesktopGetsNothing()
    {
        AllowScreen();
        Desktop.Verdict = RelayVerdict.Ready(3389);
        Desktop.Genuine = false;
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        var refused = await phone.Next(ShellEnvelope.Error);
        Assert.Equal(("rdp_unavailable", "service"), (refused.Reason, refused.Detail));
        // Still a shell connection.
        await phone.Send("{\"t\":\"list\"}");
        await phone.Next(ShellEnvelope.Sessions);
    }

    [Fact]
    public async Task AFifthQuickOpenIsTryLaterWithWhen()
    {
        AllowScreen();
        Desktop.Verdict = RelayVerdict.Ready(3389);
        for (var i = 0; i < RelayRateLimit.DefaultCap; i++)
        {
            // Each a quick failure (what guessing looks like): ended within seconds, its view freed.
            using (var quick = await Proven())
            {
                await quick.Send("{\"t\":\"rdp\"}");
                await quick.Next(ShellEnvelope.RdpReady);
            }
            await Task.Delay(300);
        }
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        var later = await phone.Next(ShellEnvelope.Error);
        Assert.Equal("try_later", later.Reason);
        Assert.InRange(later.RetryAfter ?? 0, 1, 600);
    }

    [Fact]
    public async Task UnavailableComesBeforeTryLater()
    {
        AllowScreen();
        Desktop.Verdict = RelayVerdict.No("exposed");
        using var phone = await Proven();
        await phone.Send("{\"t\":\"rdp\"}");
        var refused = await phone.Next(ShellEnvelope.Error);
        Assert.Equal(("rdp_unavailable", "exposed"), (refused.Reason, refused.Detail));
    }
}
