using System.Security.AccessControl;
using System.Security.Principal;
using Passthrough.Core.Pipe;
using Passthrough.Windows.Pipes;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>
/// The service's pipe on a real Windows pipe. The service's own SID can't own a pipe this test makes, so this account
/// stands in for it: what is checked is the checks.
/// </summary>
public sealed class ServicePipeTests
{
    private static string Me()
    {
        using var me = WindowsIdentity.GetCurrent();
        return me.User!.Value;
    }

    [Fact]
    public async Task TheServiceReadsWhoConnectedFromTheirToken()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        await using var server = ServicePipe.CreateInstance(first: true, name, serviceSid: Me());
        var accepted = server.WaitForConnectionAsync();
        await using var client = ServicePipe.Connect(name, serviceSid: Me(), servicePid: () => Environment.ProcessId);
        await accepted;
        var peer = ServicePipe.Peer(server);
        Assert.NotNull(peer);
        Assert.Equal(Me(), peer!.Account);
        Assert.NotEqual(0, peer.Session);
        using var identity = WindowsIdentity.GetCurrent();
        // Whatever this test runs as, the token says it truly (CI's runner is elevated; a developer's prompt may not be).
        Assert.Equal(Shell.UserEnvironment.IsElevated(), peer.Elevated);
        Assert.Equal(peer.Elevated ? PipePeer.Integrity.High : PipePeer.Integrity.Medium, peer.Level);
    }

    [Fact]
    public async Task APipeSomeoneElseOwnsIsNeverTalkedTo()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        // A squatter: the name, made by this account, while the tray app expects the service's SID.
        await using var squatter = ServicePipe.CreateInstance(first: true, name, serviceSid: Me());
        _ = squatter.WaitForConnectionAsync();
        Assert.Throws<ServicePipe.ImpostorException>(() => ServicePipe.Connect(name, serviceSid: "S-1-5-80-1-2-3-4-5", servicePid: () => Environment.ProcessId));
    }

    [Fact]
    public async Task APipeServedByAnotherProcessIsNeverTalkedTo()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        await using var server = ServicePipe.CreateInstance(first: true, name, serviceSid: Me());
        _ = server.WaitForConnectionAsync();
        Assert.Throws<ServicePipe.ImpostorException>(() => ServicePipe.Connect(name, serviceSid: Me(), servicePid: () => Environment.ProcessId + 1));
    }

    [Fact]
    public void NoServiceIsSaidPlainly() =>
        Assert.Throws<ServicePipe.NotThereException>(() => ServicePipe.Connect("Passthrough.Test.missing." + Guid.NewGuid().ToString("N")));

    [Fact]
    public async Task TheNameCantBeTakenWhileTheServiceHoldsIt()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        await using var service = ServicePipe.CreateInstance(first: true, name, serviceSid: Me());
        Assert.ThrowsAny<System.ComponentModel.Win32Exception>(() => ServicePipe.CreateInstance(first: true, name, serviceSid: Me()));
    }

    [Fact]
    public void ThePipesMaskForUsersLeavesOutCreatingAnInstance()
    {
        var acl = new RawSecurityDescriptor(ServicePipe.Sddl(Passthrough.Core.Setup.ServiceDefinition.Sid)).DiscretionaryAcl!;
        var interactive = new SecurityIdentifier(WellKnownSidType.InteractiveSid, null);
        const int createInstance = 0x4;
        var users = acl.OfType<CommonAce>().Single(a => a.SecurityIdentifier == interactive);
        Assert.Equal(0, users.AccessMask & createInstance);
        Assert.Contains(acl.OfType<CommonAce>(), a => a.AceType == AceType.AccessDenied && a.SecurityIdentifier == new SecurityIdentifier(WellKnownSidType.NetworkSid, null));
    }
}
