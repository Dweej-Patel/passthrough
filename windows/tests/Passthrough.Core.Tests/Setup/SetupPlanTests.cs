using Passthrough.Core.Setup;
using Xunit;

namespace Passthrough.Core.Tests.Setup;

public sealed class SetupPlanTests
{
    private const string Me = "S-1-5-21-1-2-3-1001";
    private const string Other = "S-1-5-21-1-2-3-1002";

    private static (SetupResult Result, List<StepReport> Reports, SetupContext Context) Run(FakePc pc, IReadOnlyList<ISetupStep> plan,
        string? asking = Me, bool continuePastFailure = false, int build = 26100)
    {
        var reports = new List<StepReport>();
        var context = new SetupContext { System = pc.System(build), Source = FakePc.Source, AskingAccount = asking };
        return (SetupEngine.Run(plan, context, reports.Add, continuePastFailure), reports, context);
    }

    private static FakePc Installed()
    {
        var pc = new FakePc();
        pc.AddBuild();
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.InstallOrUpdate(update: false)).Result.Result);
        return pc;
    }

    [Fact]
    public void ServiceSidMatchesWindows()
    {
        // TrustedInstaller's SID is the service SID of "TrustedInstaller".
        Assert.Equal("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", ServiceSid.For("TrustedInstaller"));
        Assert.Equal("S-1-5-80-4278898763-3377807445-3347082863-1725487610-3689323215", ServiceSid.For(ServiceDefinition.Name));
        Assert.Equal(ServiceSid.For("passthroughservice"), ServiceDefinition.Sid);
    }

    [Fact]
    public void ServiceSecurityGivesUsersNoControls()
    {
        var sddl = ServiceDefinition.ServiceSddl([Me]);
        // Interactive users: query and interrogate, no user-defined control (CR), start (RP) or stop (WP).
        Assert.Contains("(A;;CCLCSWLORC;;;IU)", sddl);
        Assert.Contains($"(A;;RPLCLO;;;{Me})", sddl);
        Assert.DoesNotContain("CR;;;IU", sddl);
    }

    [Fact]
    public void InstallSetsEverythingUp()
    {
        var pc = Installed();
        var machine = pc.System().Machine;
        Assert.Equal(new ServiceConfig($"\"{machine.ServiceExe}\" --service", ServiceStart.Automatic), pc.Service);
        Assert.Equal([Me], pc.ServiceAccounts);
        Assert.True(pc.Running);
        var state = InstallState.Decode(pc.FileBytes[machine.StateFile])!;
        Assert.Equal([Me], state.AllowedAccounts);
        Assert.Equal("0.9.0+abc", state.Build);
        Assert.StartsWith(machine.ProgramFolder + @"\0.9.0-abc-", state.InstallFolder);
        Assert.True(state.Created.Service && state.Created.DataFolder && state.Created.ProgramFolder && state.Created.Shortcut);
        Assert.Equal(ServiceDefinition.RuleNames, state.FirewallRules);
        Assert.Equal("app 0.9.0+abc"u8.ToArray(), pc.FileBytes[WinPath.Join(state.InstallFolder, "Passthrough.exe")]);
        Assert.Equal("console"u8.ToArray(), pc.FileBytes[WinPath.Join(state.InstallFolder, @"x64\OpenConsole.exe")]);
        // The exe whose path never changes is the service's, and what Start at login and the Start menu run.
        Assert.Equal("service 0.9.0+abc"u8.ToArray(), pc.FileBytes[machine.ServiceExe]);
        Assert.Equal((machine.ServiceExe, "--launch", WinPath.Join(state.InstallFolder, "Passthrough.exe")), pc.Links[machine.ShortcutPath]);
        Assert.Equal(state.InstallFolder, pc.Registry!["InstallFolder"]);
        Assert.Equal("1", pc.Registry["Enabled"]);
        Assert.False(pc.Registry.ContainsKey("Updating"));
        Assert.Equal(ServiceDefinition.DataFolderSddl, pc.FolderSddl[machine.DataFolder]);
        Assert.Equal(ServiceDefinition.StoreFolderSddl, pc.FolderSddl[machine.StoreFolder]);
        Assert.All(pc.Rules, r => Assert.True(r.Enabled));
        Assert.Equal(machine.ServiceExe, pc.Rules.Single(r => r.Name == ServiceDefinition.UdpRuleName).Program);
    }

    [Fact]
    public void WindowsTenGetsNoTcpRule()
    {
        var pc = new FakePc();
        pc.AddBuild();
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.InstallOrUpdate(false), build: 19045).Result.Result);
        Assert.DoesNotContain(pc.Rules, r => r.Name == ServiceDefinition.TcpRuleName);
        Assert.Contains(pc.Rules, r => r.Name == ServiceDefinition.PairingRuleName);
    }

    [Fact]
    public void RunningInstallAgainRepairsIntoAFreshFolderAndTidiesTheOldOne()
    {
        var pc = Installed();
        var machine = pc.System().Machine;
        var first = InstallState.Decode(pc.FileBytes[machine.StateFile])!.InstallFolder;
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.InstallOrUpdate(false)).Result.Result);
        var second = InstallState.Decode(pc.FileBytes[machine.StateFile])!;
        Assert.NotEqual(first, second.InstallFolder);
        Assert.False(pc.FolderExists(first));
        Assert.Equal(3, pc.Rules.Count);
        Assert.Equal([Me], second.AllowedAccounts);
        Assert.True(second.Created.Service); // still recorded as Passthrough's own
    }

    [Fact]
    public void AnOldFolderInUseIsLeftForTheRestart()
    {
        var pc = Installed();
        var machine = pc.System().Machine;
        var first = InstallState.Decode(pc.FileBytes[machine.StateFile])!.InstallFolder;
        pc.InUse.Add(first);
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.InstallOrUpdate(true)).Result.Result);
        Assert.Equal([first], InstallState.Decode(pc.FileBytes[machine.StateFile])!.StaleFolders);
    }

    [Fact]
    public void UpdateStopsTheServiceAsAnUpdateAndStartsTheNewOne()
    {
        var pc = Installed();
        pc.AddBuild("0.9.1+def");
        pc.Calls.Clear();
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(true));
        Assert.Equal(SetupResult.Ok, result.Result);
        Assert.True(pc.Calls.IndexOf("stop") < pc.Calls.IndexOf("write Passthrough.Service.exe"));
        Assert.True(pc.Running);
        Assert.Equal("service 0.9.1+def"u8.ToArray(), pc.FileBytes[pc.System().Machine.ServiceExe]);
        Assert.False(pc.Registry!.ContainsKey("Updating"));
    }

    [Fact]
    public void AnOlderBuildNeverDowngrades()
    {
        var pc = Installed();
        pc.AddBuild("0.8.0+old");
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(true));
        Assert.Equal("check", result.FailedStep);
        Assert.Contains("older than the one installed", result.Error);
        Assert.Equal(4, result.ExitCode);
    }

    [Fact]
    public void UpdateNeedsAnInstall()
    {
        var pc = new FakePc();
        pc.AddBuild();
        Assert.Equal("check", Run(pc, SetupPlans.InstallOrUpdate(true)).Result.FailedStep);
    }

    [Fact]
    public void AFrameworkDependentBuildIsRefused()
    {
        var pc = new FakePc();
        pc.AddBuild(selfContained: false);
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(false));
        Assert.Equal("check", result.FailedStep);
        Assert.Contains("needs .NET installed for every account", result.Error);
        Assert.Empty(pc.Calls);
    }

    [Fact]
    public void AFileChangedAfterTheBuildIsRefusedAndNothingStays()
    {
        var pc = new FakePc();
        pc.AddBuild();
        pc.FileBytes[WinPath.Join(FakePc.Source, "coreclr.dll")] = "planted"u8.ToArray();
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(false));
        Assert.Equal("stage", result.FailedStep);
        Assert.True(result.Undone);
        Assert.Equal("", pc.Leftovers());
    }

    [Fact]
    public void APlantedDataFolderIsRefusedAndKept()
    {
        var pc = new FakePc();
        pc.AddBuild();
        pc.PlantedFolders.Add(@"C:\ProgramData\Passthrough");
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(false));
        Assert.Equal("data-folder", result.FailedStep);
        Assert.Contains("wasn't made by Passthrough", result.Error);
        Assert.True(pc.FolderExists(@"C:\ProgramData\Passthrough"));
    }

    public static TheoryData<string> FailingCalls => new()
    {
        "create Passthrough", "write install.json", "write-new", "write Passthrough.Service.exe", "configure", "add-rule", "registry", "shortcut", "start",
    };

    /// <summary>A failure at any step puts back what the run had changed: on a clean PC, nothing is left.</summary>
    [Theory]
    [MemberData(nameof(FailingCalls))]
    public void AFailureAnywhereLeavesACleanPcClean(string failing)
    {
        var pc = new FakePc { FailOn = failing };
        pc.AddBuild();
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(false));
        Assert.Equal(SetupResult.Failed, result.Result);
        Assert.True(result.Undone, result.Error);
        Assert.Equal(2, result.ExitCode);
        pc.HasProfile = false; // a service that ran once leaves a profile; remove deletes it
        Assert.Equal("", pc.Leftovers());
    }

    [Fact]
    public void AFailedUpdateGoesBackToTheOldBuild()
    {
        var pc = Installed();
        var machine = pc.System().Machine;
        var before = InstallState.Decode(pc.FileBytes[machine.StateFile])!;
        var rules = pc.Rules.ToList();
        pc.AddBuild("0.9.1+def");
        pc.StartFailures = 1;
        var (result, _, _) = Run(pc, SetupPlans.InstallOrUpdate(true));
        Assert.Equal("start", result.FailedStep);
        Assert.True(result.Undone, result.Error);
        Assert.Equal("service 0.9.0+abc"u8.ToArray(), pc.FileBytes[machine.ServiceExe]);
        Assert.Equal(before.InstallFolder, InstallState.Decode(pc.FileBytes[machine.StateFile])!.InstallFolder);
        Assert.Equal(before.InstallFolder, pc.Registry!["InstallFolder"]);
        Assert.Equal(rules, pc.Rules);
        Assert.Equal(WinPath.Join(before.InstallFolder, "Passthrough.exe"), pc.Links[machine.ShortcutPath].Icon);
        Assert.True(pc.FolderExists(before.InstallFolder));
        Assert.Single(pc.Folders(machine.ProgramFolder));
    }

    [Fact]
    public void TurnOffAndOnAgain()
    {
        var pc = Installed();
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.TurnOff()).Result.Result);
        Assert.Equal("0", pc.Registry!["Enabled"]);
        Assert.False(pc.Running);
        Assert.Equal(ServiceStart.Disabled, pc.Service!.StartType);
        Assert.All(pc.Rules, r => Assert.False(r.Enabled));
        // Enabled=0 is written before the stop, so the service knows to tell phones "turned off".
        Assert.True(pc.Calls.IndexOf("registry") < pc.Calls.IndexOf("stop"));

        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.InstallOrUpdate(false)).Result.Result);
        Assert.Equal("1", pc.Registry!["Enabled"]);
        Assert.True(pc.Running);
        Assert.Equal(ServiceStart.Automatic, pc.Service!.StartType);
        Assert.All(pc.Rules, r => Assert.True(r.Enabled));
    }

    [Fact]
    public void RemoveLeavesNothing()
    {
        var pc = Installed();
        var (result, _, _) = Run(pc, SetupPlans.RemoveAll(), continuePastFailure: true);
        Assert.Equal(SetupResult.Ok, result.Result);
        Assert.Equal("", pc.Leftovers());
        // The profile, with the service's keys, goes after the service.
        Assert.True(pc.Calls.IndexOf("delete-service") < pc.Calls.IndexOf("delete-profile"));
        Assert.DoesNotContain(pc.Calls, c => c.StartsWith("control", StringComparison.Ordinal));
    }

    [Fact]
    public void RemoveCarriesOnPastAFailureAndSaysWhich()
    {
        var pc = Installed();
        pc.FailOn = "delete-registry";
        var (result, _, _) = Run(pc, SetupPlans.RemoveAll(), continuePastFailure: true);
        Assert.Equal("registry", result.FailedStep);
        Assert.Equal(3, result.ExitCode);
        Assert.Null(pc.Service);
        Assert.Empty(pc.Rules);
        Assert.False(pc.FolderExists(@"C:\Program Files\Passthrough"));
    }

    [Fact]
    public void RemoveLeavesAPlantedFolderAlone()
    {
        var pc = Installed();
        pc.PlantedFolders.Add(@"C:\ProgramData\Passthrough");
        var (result, _, _) = Run(pc, SetupPlans.RemoveAll(), continuePastFailure: true);
        Assert.Equal("data-folder", result.FailedStep);
        Assert.True(pc.FolderExists(@"C:\ProgramData\Passthrough"));
    }

    [Fact]
    public void AllowAndDisallowAccounts()
    {
        var pc = Installed();
        var machine = pc.System().Machine;
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.AllowAccount(), asking: Other).Result.Result);
        Assert.Equal([Me, Other], InstallState.Decode(pc.FileBytes[machine.StateFile])!.AllowedAccounts);
        Assert.Equal([Me, Other], pc.ServiceAccounts);
        Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.DisallowAccount(Me)).Result.Result);
        Assert.Equal([Other], pc.ServiceAccounts);
    }

    [Fact]
    public void AFifthAccountIsRefused()
    {
        var pc = Installed();
        for (var i = 2; i <= 4; i++) Assert.Equal(SetupResult.Ok, Run(pc, SetupPlans.AllowAccount(), asking: $"S-1-5-21-9-{i}").Result.Result);
        var (result, _, _) = Run(pc, SetupPlans.AllowAccount(), asking: "S-1-5-21-9-5");
        Assert.Contains("already set up for 4 accounts", result.Error);
    }

    [Fact]
    public void ResultLinesRoundTrip()
    {
        var line = SetupLines.Encode(new StepReport("copy", StepState.Failed, "disk full"));
        Assert.Equal("""{"step":"copy","state":"failed","detail":"disk full"}""", line);
        Assert.Equal(new StepReport("copy", StepState.Failed, "disk full"), SetupLines.Decode(line).Step);
        var result = new SetupResult { Result = SetupResult.Failed, FailedStep = "start", Error = "x", Undone = true };
        Assert.Equal(result, SetupLines.Decode(SetupLines.Encode(result)).Result);
        Assert.Equal((null, null), SetupLines.Decode("nonsense"));
    }

    [Theory]
    [InlineData(@"Passthrough.exe", true)]
    [InlineData(@"x64\OpenConsole.exe", true)]
    [InlineData(@"..\Windows\System32\x.dll", false)]
    [InlineData(@"C:\Windows\x.dll", false)]
    [InlineData(@"\Windows\x.dll", false)]
    [InlineData(@"a/../b.dll", false)]
    [InlineData(@"x.dll:stream", false)]
    [InlineData(@"NUL.txt", false)]
    [InlineData(@"com1", false)]
    [InlineData(@"a\\b.dll", false)]
    [InlineData(@"trailing.", false)]
    public void ManifestPathsStayInTheFolder(string path, bool safe) => Assert.Equal(safe, FileManifest.IsSafeRelative(path));

    [Fact]
    public void AManifestNamingAFileTwiceIsRefused()
    {
        var entry = new FileManifest.Entry("a.dll", 1, new string('0', 64));
        Assert.Null(FileManifest.Decode(new FileManifest("1.0", [entry, entry with { Path = "A.DLL" }]).Encode()));
        Assert.NotNull(FileManifest.Decode(new FileManifest("1.0", [entry]).Encode()));
    }
}
