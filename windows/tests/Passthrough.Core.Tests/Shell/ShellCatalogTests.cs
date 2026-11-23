using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Sessions;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

public class ShellCatalogTests
{
    private sealed class Probe : IShellProbe
    {
        public HashSet<string> Files { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<string> Distributions { get; } = [];
        public string? Git { get; set; }
        public string System32 => @"C:\Windows\System32";
        public string ProgramFiles => @"C:\Program Files";
        public bool FileExists(string path) => Files.Contains(path);
        public IReadOnlyList<string> WslDistributions() => Distributions;
        public string? GitInstallFolder() => Git;
    }

    private const string Pwsh = @"C:\Program Files\PowerShell\7\pwsh.exe";
    private const string WinPs = @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
    private const string Cmd = @"C:\Windows\System32\cmd.exe";
    private const string Wsl = @"C:\Windows\System32\wsl.exe";

    [Fact]
    public void EverythingInstalledIsListed_PowerShell7First_AndTheDefault()
    {
        var probe = new Probe { Git = @"D:\Tools\Git" };
        probe.Files.UnionWith([Pwsh, WinPs, Cmd, Wsl, @"D:\Tools\Git\bin\bash.exe"]);
        probe.Distributions.AddRange(["Ubuntu", "Debian"]);
        var catalog = ShellCatalog.Discover(probe);
        Assert.Equal(["pwsh", "powershell", "cmd", "wsl:Ubuntu", "wsl:Debian", "git-bash"], catalog.Shells.Select(s => s.Id));
        Assert.Equal(["PowerShell", "Windows PowerShell", "Command Prompt", "Ubuntu", "Debian", "Git Bash"], catalog.Shells.Select(s => s.Name));
        Assert.Equal("pwsh", catalog.Default?.Id);
        Assert.Single(catalog.Shells, s => s.Default == true);
        Assert.All(catalog.Shells, s => Assert.True(HostShell.IsValidId(s.Id), s.Id));

        var standard = catalog.Resolve(null);
        Assert.Equal(("pwsh", Pwsh), (standard.Id, standard.Executable));
        Assert.Equal(["-NoLogo"], standard.Arguments);
        var ubuntu = catalog.Resolve("wsl:Ubuntu");
        Assert.Equal(Wsl, ubuntu.Executable);
        Assert.Equal(["-d", "Ubuntu", "--cd", "~"], ubuntu.Arguments);
        Assert.Equal(@"D:\Tools\Git\bin\bash.exe", catalog.Resolve("git-bash").Executable);
    }

    [Fact]
    public void WithoutPowerShell7WindowsPowerShellIsTheDefault()
    {
        var probe = new Probe();
        probe.Files.UnionWith([WinPs, Cmd]);
        var catalog = ShellCatalog.Discover(probe);
        Assert.Equal("powershell", catalog.Default?.Id);
        Assert.Equal(WinPs, catalog.Resolve(null).Executable);
        // Git in its usual place, without a registry entry.
        probe.Files.Add(@"C:\Program Files\Git\bin\bash.exe");
        Assert.Equal(@"C:\Program Files\Git\bin\bash.exe", ShellCatalog.Discover(probe).Resolve("git-bash").Executable);
    }

    [Fact]
    public void AnythingNotInTheCatalogIsRefused()
    {
        var probe = new Probe();
        probe.Files.UnionWith([Cmd, Wsl]);
        probe.Distributions.AddRange(["Ubuntu", "bad name", "x;calc", "-d", "..", ""]);
        probe.Git = @"relative\Git";
        probe.Files.Add(@"relative\Git\bin\bash.exe");
        var catalog = ShellCatalog.Discover(probe);
        Assert.Equal(["cmd", "wsl:Ubuntu"], catalog.Shells.Select(s => s.Id));
        foreach (var id in new[] { "pwsh", "wsl:bad name", "wsl:x;calc", Cmd, "CMD", "git-bash", "" })
            Assert.Equal(ShellError.BadRequest, Assert.Throws<ShellException>(() => catalog.Resolve(id)).Error);
        Assert.Equal("cmd", catalog.Default?.Id);
    }

    [Fact]
    public void APcWithNoShellSaysSo()
    {
        var catalog = ShellCatalog.Discover(new Probe());
        Assert.Empty(catalog.Shells);
        Assert.Null(catalog.Default);
        Assert.Throws<ShellException>(() => catalog.Resolve(null));
    }

    [Theory]
    [InlineData(new[] { "-NoLogo" }, "\"C:\\p\\pwsh.exe\" -NoLogo")]
    [InlineData(new[] { "-d", "Ubuntu Preview", "--cd", "~" }, "\"C:\\p\\pwsh.exe\" -d \"Ubuntu Preview\" --cd ~")]
    [InlineData(new[] { "" }, "\"C:\\p\\pwsh.exe\" \"\"")]
    [InlineData(new[] { "a\"b" }, "\"C:\\p\\pwsh.exe\" \"a\\\"b\"")]
    [InlineData(new[] { "C:\\dir with space\\" }, "\"C:\\p\\pwsh.exe\" \"C:\\dir with space\\\\\"")]
    [InlineData(new[] { "back\\\\\"slash" }, "\"C:\\p\\pwsh.exe\" \"back\\\\\\\\\\\"slash\"")]
    [InlineData(new[] { "C:\\no\\space\\" }, "\"C:\\p\\pwsh.exe\" C:\\no\\space\\")]
    public void CommandLinesQuoteAsTheRuntimeParses(string[] arguments, string expected)
    {
        Assert.Equal(expected, CommandLine.Build(@"C:\p\pwsh.exe", arguments));
    }

    [Fact]
    public void EnvironmentBlocksAreSortedWithoutRegardToCase()
    {
        var block = CommandLine.EnvironmentBlock(new Dictionary<string, string> { ["b"] = "2", ["A"] = "1", ["=C:"] = @"C:\", ["PATH"] = "x" });
        Assert.Equal("=C:=C:\\\0A=1\0b=2\0PATH=x\0\0", block);
        Assert.Equal("\0\0", CommandLine.EnvironmentBlock(new Dictionary<string, string>()));
        Assert.Throws<ArgumentException>(() => CommandLine.EnvironmentBlock(new Dictionary<string, string> { ["A=B"] = "1" }));
        Assert.Throws<ArgumentException>(() => CommandLine.EnvironmentBlock(new Dictionary<string, string> { ["A"] = "1\0X=2" }));
        Assert.Throws<ArgumentException>(() => CommandLine.Build("C:\\a\"b.exe", []));
    }
}
