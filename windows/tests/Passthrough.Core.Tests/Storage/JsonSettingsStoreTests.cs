using System.Text.Json;
using Passthrough.Core.Storage;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Storage;

public class JsonSettingsStoreTests
{
    private const string Path = "/app/settings.json";
    private const string ClientId = "0C1F6A52-1D7B-4E0E-9B7C-3A2D9E1F4B6C";

    [Fact]
    public void NoFile_StartsEmpty_WithNoNotice()
    {
        var store = new JsonSettingsStore(new MemoryFileSystem(), Path);
        Assert.Null(store.Get("clientID"));
        Assert.Null(store.Notice);
    }

    [Fact]
    public void Set_WritesATempFileDurably_ThenRenamesItOverTheFile()
    {
        var fs = new MemoryFileSystem();
        var store = new JsonSettingsStore(fs, Path);

        store.Set("clientID", ClientId);
        store.Set("androidEnabled", "false");

        Assert.Equal([$"write {Path}.tmp", $"move {Path}.tmp {Path}", $"write {Path}.tmp", $"move {Path}.tmp {Path}"], fs.Operations);
        Assert.False(fs.FileExists(Path + ".tmp"));
        var saved = JsonSerializer.Deserialize<Dictionary<string, string>>(fs.Files[Path])!;
        Assert.Equal(ClientId, saved["clientID"]);
        Assert.Equal("false", saved["androidEnabled"]);

        var again = new JsonSettingsStore(fs, Path);
        Assert.Equal((ClientId, "false"), (again.Get("clientID"), again.Get("androidEnabled")));
    }

    [Theory]
    [InlineData("write")]
    [InlineData("move")]
    public void FailedWrite_Throws_AndLeavesTheFileAndTheValuesAsTheyWere(string failing)
    {
        var fs = new MemoryFileSystem();
        var store = new JsonSettingsStore(fs, Path);
        store.Set("androidEnabled", "true");
        var before = fs.Files[Path];

        fs.Fail = (op, _) => op == failing ? new IOException("There is not enough space on the disk.") : null;
        Assert.Throws<IOException>(() => store.Set("androidEnabled", "false"));

        Assert.Equal("true", store.Get("androidEnabled"));
        Assert.Equal(before, fs.Files[Path]);
    }

    [Fact]
    public void ValuesThatAreNotStrings_AreReadLeniently_NotTreatedAsDamage()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = $$"""{"clientID":"{{ClientId}}","androidEnabled":false,"count":3,"nested":{"a":1},"none":null}""";

        var store = new JsonSettingsStore(fs, Path);

        Assert.Equal(ClientId, store.Get("clientID"));
        Assert.Equal("false", store.Get("androidEnabled"));
        Assert.Equal("3", store.Get("count"));
        Assert.Null(store.Get("nested"));
        Assert.Null(store.Get("none"));
        Assert.Null(store.Notice);
        Assert.False(fs.FileExists(Path + ".bad"));
    }

    [Fact]
    public void DamagedFile_IsKeptAsBad_TheClientIdIsRecovered_AndTheUserIsTold()
    {
        var fs = new MemoryFileSystem();
        var damaged = $$"""{"androidEnabled":"true","clientID":"{{ClientId}}","na""";
        fs.Files[Path] = damaged;

        var store = new JsonSettingsStore(fs, Path);

        Assert.Equal(ClientId, store.Get("clientID")); // phones still know this PC
        Assert.Equal(damaged, fs.Files[Path + ".bad"]);
        Assert.Equal(ClientId, JsonSerializer.Deserialize<Dictionary<string, string>>(fs.Files[Path])!["clientID"]); // saved at once
        Assert.Equal(JsonSettingsStore.DamagedNotice, store.Notice);

        store.Set("androidEnabled", "false");
        var saved = JsonSerializer.Deserialize<Dictionary<string, string>>(fs.Files[Path])!;
        Assert.Equal(ClientId, saved["clientID"]);
        Assert.Equal(damaged, fs.Files[Path + ".bad"]);
    }

    [Theory]
    [InlineData("not json at all")]
    [InlineData("[1, 2]")]
    [InlineData("\"a string\"")]
    [InlineData("")]
    public void DamagedFile_WithNoClientId_SaysPhonesMayNeedToPairAgain(string text)
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = text;

        var store = new JsonSettingsStore(fs, Path);

        Assert.Null(store.Get("clientID"));
        Assert.Equal(JsonSettingsStore.DamagedLostNotice, store.Notice);
        Assert.Equal(text, fs.Files[Path + ".bad"]);
    }

    [Fact]
    public void DamagedFile_ThatCannotBeKept_IsNeverOverwritten()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = "{broken";
        fs.Fail = (op, path) => op == "move" && path == Path ? new UnauthorizedAccessException("denied") : null;

        var store = new JsonSettingsStore(fs, Path);

        Assert.Equal(JsonSettingsStore.DamagedUnsavedNotice, store.Notice);
        Assert.Throws<InvalidOperationException>(() => store.Set("clientID", ClientId));
        Assert.Equal("{broken", fs.Files[Path]);
        Assert.Null(store.Get("clientID"));
    }

    [Fact]
    public void UnreadableFile_Throws_SoStartupCanSaySo()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = "{}";
        fs.Fail = (op, _) => op == "read" ? new IOException("The process cannot access the file") : null;
        Assert.Throws<IOException>(() => new JsonSettingsStore(fs, Path));
    }

    [Fact]
    public void RecoveredClientId_SurvivesARestart_WithNoSetInBetween()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = $$"""{"clientID":"{{ClientId}}","androidEnabled":""";

        var first = new JsonSettingsStore(fs, Path);
        Assert.Equal(ClientId, first.Get("clientID"));

        var second = new JsonSettingsStore(fs, Path);
        Assert.Equal(ClientId, second.Get("clientID"));
        Assert.Null(second.Notice); // a healthy file now
    }

    [Fact]
    public void RecoveredValues_ThatCannotBeSaved_AreRecoveredFromTheBadCopyNextTime()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path] = $$"""{"clientID":"{{ClientId}}",""";
        fs.Fail = (op, path) => op == "write" ? new IOException("There is not enough space on the disk.") : null;

        var first = new JsonSettingsStore(fs, Path);
        Assert.Equal(ClientId, first.Get("clientID"));
        Assert.Equal(JsonSettingsStore.DamagedNotice, first.Notice);
        Assert.False(fs.FileExists(Path));

        fs.Fail = (_, _) => null; // the disk has room again
        var second = new JsonSettingsStore(fs, Path);
        Assert.Equal(ClientId, second.Get("clientID"));
        Assert.Equal(JsonSettingsStore.DamagedNotice, second.Notice);
        Assert.Equal(ClientId, JsonSerializer.Deserialize<Dictionary<string, string>>(fs.Files[Path])!["clientID"]);

        var third = new JsonSettingsStore(fs, Path);
        Assert.Equal((ClientId, (string?)null), (third.Get("clientID"), third.Notice));
    }

    [Fact]
    public void RecoverySave_WhoseFinalRenameFails_KeepsTheNoticeAndRecoversFromTheBadCopyNextTime()
    {
        var fs = new MemoryFileSystem();
        var damaged = $$"""{"clientID":"{{ClientId}}",""";
        fs.Files[Path] = damaged;
        fs.Fail = (op, path) => op == "move" && path == Path + ".tmp" ? new IOException("Access is denied.") : null;

        var first = new JsonSettingsStore(fs, Path);
        Assert.Equal((ClientId, JsonSettingsStore.DamagedNotice), (first.Get("clientID"), first.Notice));
        Assert.False(fs.FileExists(Path));
        Assert.Equal(damaged, fs.Files[Path + ".bad"]);

        fs.Fail = (_, _) => null;
        var second = new JsonSettingsStore(fs, Path);
        Assert.Equal((ClientId, JsonSettingsStore.DamagedNotice), (second.Get("clientID"), second.Notice));
        Assert.Equal(ClientId, JsonSerializer.Deserialize<Dictionary<string, string>>(fs.Files[Path])!["clientID"]);
        Assert.False(fs.FileExists(Path + ".tmp"));
    }

    [Fact]
    public void BadCopy_ThatCannotBeRead_AtTheNextLaunch_StartsEmptyWithoutThrowing()
    {
        var fs = new MemoryFileSystem();
        fs.Files[Path + ".bad"] = $$"""{"clientID":"{{ClientId}}",""";
        fs.Fail = (op, path) => op == "read" && path == Path + ".bad" ? new IOException("The process cannot access the file") : null;

        var store = new JsonSettingsStore(fs, Path);

        Assert.Null(store.Get("clientID"));
        Assert.Null(store.Notice);
        Assert.False(fs.FileExists(Path));
        store.Set("androidEnabled", "true"); // settings still work
        Assert.Equal("true", new JsonSettingsStore(fs, Path).Get("androidEnabled"));
    }
}
