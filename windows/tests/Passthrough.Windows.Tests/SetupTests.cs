using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Passthrough.Core.Setup;
using Passthrough.Windows.Pipes;
using Passthrough.Windows.Setup;
using Xunit;

namespace Passthrough.Windows.Tests;

/// <summary>What the install builds on that only Windows can check: SIDs, security descriptors, the pipes' ends.</summary>
public sealed class SetupTests
{
    [Fact]
    public void TheServiceSidIsWhatWindowsCallsItsAccount()
    {
        // TrustedInstaller exists on every PC: Windows resolves its name to the SID computed the same way.
        var sid = (SecurityIdentifier)new NTAccount(@"NT SERVICE\TrustedInstaller").Translate(typeof(SecurityIdentifier));
        Assert.Equal(ServiceSid.For("TrustedInstaller"), sid.Value);
    }

    [Fact]
    public void EveryDescriptorParses()
    {
        foreach (var sddl in new[] { ServiceDefinition.DataFolderSddl, ServiceDefinition.StoreFolderSddl, ServiceDefinition.LogsFolderSddl, ServiceDefinition.ProgramFolderSddl })
        {
            var security = new DirectorySecurity();
            security.SetSecurityDescriptorSddlForm(sddl);
            Assert.Equal(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), security.GetOwner(typeof(SecurityIdentifier)));
            Assert.True(security.AreAccessRulesProtected);
        }
        var service = new RawSecurityDescriptor(ServiceDefinition.ServiceSddl(["S-1-5-21-1-2-3-1001"]));
        Assert.Equal(4, service.DiscretionaryAcl!.Count);
    }

    [Fact]
    public void InteractiveUsersCantSendTheServiceAControl()
    {
        var acl = new RawSecurityDescriptor(ServiceDefinition.ServiceSddl(["S-1-5-21-1-2-3-1001"])).DiscretionaryAcl!;
        const int userDefinedControl = 0x0100, stop = 0x0020, start = 0x0010, changeConfig = 0x0002;
        var interactive = new SecurityIdentifier(WellKnownSidType.InteractiveSid, null);
        var account = new SecurityIdentifier("S-1-5-21-1-2-3-1001");
        foreach (CommonAce ace in acl)
        {
            if (ace.SecurityIdentifier == interactive) Assert.Equal(0, ace.AccessMask & (userDefinedControl | stop | start | changeConfig));
            if (ace.SecurityIdentifier == account)
            {
                Assert.NotEqual(0, ace.AccessMask & start);
                Assert.Equal(0, ace.AccessMask & (userDefinedControl | stop | changeConfig));
            }
        }
    }

    [Fact]
    public void AFolderAnotherAccountCanWriteIsNotTrusted()
    {
        var folder = Path.Combine(Path.GetTempPath(), "pt-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            // Made by this test, so owned by this account (or Administrators when the runner is elevated), and in
            // %TEMP% it inherits this account's full control: never trusted.
            Assert.Equal(FolderCheck.Planted, new WindowsSecuredFiles().Check(folder));
            Assert.Equal(FolderCheck.Missing, new WindowsSecuredFiles().Check(folder + "-missing"));
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void ReadLockedRefusesALink()
    {
        var folder = Path.Combine(Path.GetTempPath(), "pt-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var real = Path.Combine(folder, "real.dll");
            File.WriteAllText(real, "x");
            Assert.Equal("x"u8.ToArray(), new WindowsSecuredFiles().ReadLocked(real));
            var link = Path.Combine(folder, "link.dll");
            try { File.CreateSymbolicLink(link, real); }
            catch (IOException) { return; } // no symlink right without Developer Mode or elevation
            Assert.Throws<SetupException>(() => new WindowsSecuredFiles().ReadLocked(link));
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public async Task ThePipeKnowsWhoServesItAndRefusesASecondCreator()
    {
        var name = "Passthrough.Test." + Guid.NewGuid().ToString("N");
        using var me = WindowsIdentity.GetCurrent();
        await using var server = PipeNative.CreateServer(name, $"D:P(A;;GA;;;{me.User})(A;;GA;;;SY)", first: true, maxInstances: 1);
        // First instance only: nobody else can take the name, or add an instance, while it is held.
        Assert.ThrowsAny<System.ComponentModel.Win32Exception>(() => PipeNative.CreateServer(name, $"D:P(A;;GA;;;{me.User})", first: true, maxInstances: 1));
        var accepted = server.WaitForConnectionAsync();
        await using var client = PipeNative.OpenClient(name, anonymous: true);
        await accepted;
        Assert.Equal(Environment.ProcessId, PipeNative.ServerProcessId(client.SafePipeHandle));
        Assert.Equal(Environment.ProcessId, PipeNative.ClientProcessId(server.SafePipeHandle));
        Assert.Equal(me.User, PipeNative.ProcessAccount(Environment.ProcessId)!.Value.User);
        Assert.Equal(me.Owner, PipeNative.Owner(client.SafePipeHandle));
        await client.WriteAsync("hi\n"u8.ToArray());
        var buffer = new byte[3];
        await server.ReadExactlyAsync(buffer);
        Assert.Equal("hi\n", Encoding.UTF8.GetString(buffer));
    }

    [Fact]
    public async Task TheSetupPipeCarriesInputOneWayAndLinesTheOther()
    {
        // The elevated end can't be run here; its half of the conversation is played over the real pipe.
        var hex = Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
        using var me = WindowsIdentity.GetCurrent();
        await using var server = PipeNative.CreateServer(ElevatedSetup.PipePrefix + hex, $"D:P(A;;GA;;;{me.User})", first: true, maxInstances: 1);
        var accepted = server.WaitForConnectionAsync();
        var elevated = Task.Run(() =>
        {
            using var reporter = SetupReporter.Connect(hex)!;
            Assert.Equal(me.User, reporter.AskingAccount);
            Assert.Equal("https://relay.example", reporter.Input.RelayUrl);
            reporter.Report(new StepReport("check", StepState.Skipped));
            reporter.Report(new SetupResult { Result = SetupResult.Ok });
        });
        await accepted;
        await server.WriteAsync(Encoding.UTF8.GetBytes(new SetupInput { RelayUrl = "https://relay.example" }.Encode() + "\n"));
        using var reader = new StreamReader(server);
        Assert.Equal(new StepReport("check", StepState.Skipped), SetupLines.Decode((await reader.ReadLineAsync())!).Step);
        Assert.Equal(SetupResult.Ok, SetupLines.Decode((await reader.ReadLineAsync())!).Result!.Result);
        await elevated;
    }

    [Fact]
    public void AReporterForANameThatIsntHexIsRefused() => Assert.Null(SetupReporter.Connect(@"..\..\x"));
}
