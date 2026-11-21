using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class AdbLocatorTests
{
    private static readonly Dictionary<string, string> Env = new()
    {
        ["ANDROID_HOME"] = "C:\\home",
        ["ANDROID_SDK_ROOT"] = "C:\\root",
        ["LOCALAPPDATA"] = "C:\\Users\\me\\AppData\\Local",
        ["PATH"] = "C:\\first;C:\\second\\",
    };

    private static AdbLocator Locator(Func<string, bool> exists) =>
        new(k => Env.GetValueOrDefault(k), exists, ";", "adb.exe", '\\');

    [Fact]
    public void Locator_SearchOrder()
    {
        var local = "C:\\Users\\me\\AppData\\Local\\Android\\Sdk\\platform-tools\\adb.exe";
        var found = Locator(p => p == local || p == "C:\\second\\adb.exe").Find();

        Assert.Equal(local, found);
        Assert.Null(Locator(_ => false).Find());
    }

    [Fact]
    public void Locator_AndroidHomeWinsOverEverything()
    {
        Assert.Equal("C:\\home\\platform-tools\\adb.exe", Locator(_ => true).Find());
    }

    [Fact]
    public void Locator_FallsBackToPathAndSkipsTrailingSeparator()
    {
        Assert.Equal("C:\\second\\adb.exe", Locator(p => p == "C:\\second\\adb.exe").Find());
    }

    [Fact]
    public void Locator_MissingVariablesAreSkipped()
    {
        var locator = new AdbLocator(_ => null, _ => true, ":", "adb", '/');
        Assert.Null(locator.Find());
    }

    private static AdbLocator Fresh(Dictionary<string, string> process, Dictionary<string, string>? user, Dictionary<string, string>? machine, Func<string, bool> exists) =>
        new(new EnvironmentSources(
                k => process.GetValueOrDefault(k),
                user is null ? null : k => user.GetValueOrDefault(k),
                machine is null ? null : k => machine.GetValueOrDefault(k)),
            exists, ";", "adb.exe", '\\');

    [Fact]
    public void Locator_PathInstalledAfterStart_FoundWithoutRestart()
    {
        // winget adds platform-tools to the user's PATH; the process's own PATH is the snapshot from start-up.
        var process = new Dictionary<string, string> { ["PATH"] = "C:\\Windows" };
        var user = new Dictionary<string, string>();
        var machine = new Dictionary<string, string> { ["PATH"] = "C:\\Windows;C:\\Windows\\System32" };
        var locator = Fresh(process, user, machine, p => p == "C:\\tools\\platform-tools\\adb.exe");

        Assert.Null(locator.Find());
        user["PATH"] = "C:\\tools\\platform-tools";

        Assert.Equal("C:\\tools\\platform-tools\\adb.exe", locator.Find());
    }

    [Fact]
    public void Locator_PathEntriesFromMachineThenUserThenProcess()
    {
        var process = new Dictionary<string, string> { ["PATH"] = "C:\\p" };
        var user = new Dictionary<string, string> { ["PATH"] = "C:\\u" };
        var machine = new Dictionary<string, string> { ["PATH"] = "C:\\m" };
        var tried = new List<string>();

        Assert.Null(Fresh(process, user, machine, p => { tried.Add(p); return false; }).Find());

        Assert.Equal(["C:\\m\\adb.exe", "C:\\u\\adb.exe", "C:\\p\\adb.exe"], tried);
    }

    [Fact]
    public void Locator_StoredVariableWinsOverTheStartUpSnapshot()
    {
        var process = new Dictionary<string, string> { ["ANDROID_HOME"] = "C:\\old" };
        var user = new Dictionary<string, string> { ["ANDROID_HOME"] = "C:\\new" };

        Assert.Equal("C:\\new\\platform-tools\\adb.exe", Fresh(process, user, null, _ => true).Find());
    }

    [Fact]
    public void Locator_ExpandsVariablesInStoredValues()
    {
        // The registry keeps PATH entries such as %LOCALAPPDATA%\Microsoft\WinGet\Links unexpanded (REG_EXPAND_SZ).
        var process = new Dictionary<string, string> { ["LOCALAPPDATA"] = "C:\\Users\\me\\AppData\\Local" };
        var user = new Dictionary<string, string> { ["PATH"] = "%LOCALAPPDATA%\\Microsoft\\WinGet\\Links;%NOT_SET%\\bin" };
        var tried = new List<string>();

        Fresh(process, user, null, p => { tried.Add(p); return false; }).Find();

        Assert.Contains("C:\\Users\\me\\AppData\\Local\\Microsoft\\WinGet\\Links\\adb.exe", tried);
        Assert.Contains("%NOT_SET%\\bin\\adb.exe", tried); // an unknown name is left as written
    }

    [Fact]
    public void Locator_StoredSourceThatThrows_CountsAsUnset()
    {
        var locator = new AdbLocator(
            new EnvironmentSources(k => k == "PATH" ? "C:\\p" : null, _ => throw new System.Security.SecurityException("registry"), null),
            p => p == "C:\\p\\adb.exe", ";", "adb.exe", '\\');

        Assert.Equal("C:\\p\\adb.exe", locator.Find());
    }
}
