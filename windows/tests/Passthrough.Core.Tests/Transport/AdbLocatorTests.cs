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
}
