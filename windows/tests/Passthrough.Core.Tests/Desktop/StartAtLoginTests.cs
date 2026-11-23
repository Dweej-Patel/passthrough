using Passthrough.Core.Desktop;
using Xunit;

namespace Passthrough.Core.Tests.Desktop;

public class StartAtLoginTests
{
    private const string Exe = @"C:\Users\dee\Apps\Passthrough\Passthrough.exe";

    [Fact]
    public void Command_IsTheQuotedPath() => Assert.Equal("\"" + Exe + "\"", StartAtLogin.Command(Exe));

    [Theory]
    [InlineData("\"C:\\Users\\dee\\Apps\\Passthrough\\Passthrough.exe\"", true)]
    [InlineData("C:\\Users\\dee\\Apps\\Passthrough\\Passthrough.exe", true)]
    [InlineData("  \"c:\\users\\DEE\\apps\\passthrough\\PASSTHROUGH.EXE\" ", true)] // Windows paths ignore case
    [InlineData("\"C:\\old\\bin\\Debug\\Passthrough.exe\"", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void PointsAt(string? value, bool expected) => Assert.Equal(expected, StartAtLogin.PointsAt(value, Exe));

    [Fact]
    public void PointsAt_UnknownExe_IsFalse() => Assert.False(StartAtLogin.PointsAt("\"" + Exe + "\"", null));

    [Fact]
    public void Repair_RewritesOnlyAStaleEntry()
    {
        Assert.Equal("\"" + Exe + "\"", StartAtLogin.Repair("\"C:\\old\\Passthrough.exe\"", Exe)); // moved build: point at this one
        Assert.Null(StartAtLogin.Repair("\"" + Exe + "\"", Exe));                                   // already right
        Assert.Null(StartAtLogin.Repair(null, Exe));                                                 // not enabled: leave it off
        Assert.Null(StartAtLogin.Repair("\"C:\\old\\Passthrough.exe\"", null));                     // path unknown
    }
}

public sealed class StartAtLoginInstalledTests
{
    private const string Launcher = @"C:\Program Files\Passthrough\Passthrough.Service.exe";
    private const string Installed = @"C:\Program Files\Passthrough\2026.11.21-1a2b3c4d\Passthrough.exe";
    private const string Elsewhere = @"D:\src\Passthrough.exe";

    [Fact]
    public void InstalledTheEntryIsTheLauncher()
    {
        Assert.Equal($"\"{Launcher}\" --launch", StartAtLogin.EnabledValue(Installed, Launcher));
        Assert.True(StartAtLogin.IsEnabled($"\"{Launcher}\" --launch", Installed, Launcher));
        // The installed copy moves an old entry to the launcher, so updates never leave it pointing at nothing.
        Assert.Equal($"\"{Launcher}\" --launch", StartAtLogin.Repair($"\"{Installed}\"", Installed, Launcher, isInstalledCopy: true));
        Assert.Null(StartAtLogin.Repair($"\"{Launcher}\" --launch", Installed, Launcher, isInstalledCopy: true));
    }

    [Fact]
    public void ABuildRunFromElsewhereNeverTakesTheEntry()
    {
        Assert.Null(StartAtLogin.Repair($"\"{Launcher}\" --launch", Elsewhere, Launcher, isInstalledCopy: false));
        Assert.Null(StartAtLogin.Repair($"\"{Installed}\"", Elsewhere, Launcher, isInstalledCopy: false));
        Assert.Null(StartAtLogin.Repair(null, Installed, Launcher, isInstalledCopy: true)); // off stays off
    }
}
