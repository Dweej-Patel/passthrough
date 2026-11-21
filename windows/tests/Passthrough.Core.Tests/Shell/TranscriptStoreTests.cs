using System.Text;
using System.Text.Json;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Sessions;
using Xunit;
using Output = Passthrough.Core.Shell.ShellReplayChunk.Output;
using Resize = Passthrough.Core.Shell.ShellReplayChunk.Resize;

namespace Passthrough.Core.Tests.Shell;

/// <summary>A port of TranscriptStoreTests.swift (its POSIX-mode and backup cases become the id rules).</summary>
public sealed class TranscriptStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"TranscriptStoreTests-{Guid.NewGuid():N}");

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private static DateTimeOffset T(double seconds) => DateTimeOffset.UnixEpoch.AddSeconds(seconds);
    private static byte[] B(string text) => Encoding.UTF8.GetBytes(text);
    private static string S(byte[] data) => Encoding.UTF8.GetString(data);
    private static Output O(string text) => new(B(text));

    /// <summary>Read while the writer still has it open, as the store reads it.</summary>
    private static string ReadShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return new StreamReader(stream, Encoding.UTF8).ReadToEnd();
    }

    private TranscriptStore Store(long castLimit = TranscriptStore.DefaultCastLimit, long checkpoint = TranscriptStore.SizeCheckpoint) =>
        new(_directory, castLimit, checkpoint);

    private static TranscriptWriter Writer(TranscriptStore store, string id = "s1", double at = 1_000) =>
        store.Begin(id, "zsh", "Pixel", 80, 24, T(at));

    private string CastPath(string id = "s1") => Path.Combine(_directory, id + ".cast");
    private string[] Lines(string id = "s1") => ReadShared(CastPath(id)).Split('\n', StringSplitOptions.RemoveEmptyEntries);

    [Fact]
    public void RoundTripOutput_AndSplitUtf8IsHeldUntilComplete()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append(B("hello "), T(1_001));
        writer.Append(B("world"), T(1_002));
        Assert.Equal("hello world", S(store.Output("s1")));

        var euro = B("€");
        var other = Writer(store, "s2");
        other.Append(euro.AsSpan(0, 2), T(1_001));
        other.Append(euro.AsSpan(2, 1), T(1_002));
        Assert.Equal("€", S(store.Output("s2")));
        Assert.DoesNotContain("�", ReadShared(CastPath("s2")));
    }

    [Fact]
    public void IncompleteTailIsReplacedOnFinish()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append(B("€").AsSpan(0, 2), T(1_001));
        writer.Finish(0, T(1_002));
        Assert.Equal("�", S(store.Output("s1")));
    }

    [Fact]
    public void HeaderIsAsciicastV2()
    {
        Writer(Store());
        using var header = JsonDocument.Parse(Lines()[0]);
        var root = header.RootElement;
        Assert.Equal(2, root.GetProperty("version").GetInt32());
        Assert.Equal(80, root.GetProperty("width").GetInt32());
        Assert.Equal(24, root.GetProperty("height").GetInt32());
        Assert.Equal(1_000, root.GetProperty("timestamp").GetInt32());
        Assert.Equal("zsh", root.GetProperty("title").GetString());
    }

    [Fact]
    public void EntriesNewestFirstWithExitStatus_AndAnUnfinishedOneHasNoEnd()
    {
        var store = Store();
        var first = Writer(store, "a", 1_000);
        var second = Writer(store, "b", 2_000);
        first.Append(B("x"), T(1_001));
        first.Finish(3, T(1_500));
        Assert.Null(store.Entries()[0].EndedAt);
        Assert.True(store.Entries()[1].Bytes > 0);
        second.Finish(null, T(2_500));
        var entries = store.Entries();
        Assert.Equal(["b", "a"], entries.Select(e => e.Id));
        Assert.Equal(3, entries[1].ExitStatus);
        Assert.Equal(1_500, entries[1].EndedAt);
        Assert.Equal(1_000, entries[1].StartedAt);
        Assert.Equal("zsh", entries[1].Title);
        Assert.Equal("Pixel", entries[1].PhoneLabel);
        Assert.Null(entries[0].ExitStatus);
        Assert.Equal(2_500, entries[0].EndedAt);
    }

    [Fact]
    public void DeleteAndTotalBytes()
    {
        var store = Store();
        var a = Writer(store, "a");
        var b = Writer(store, "b");
        a.Append(B("one"), T(1_001));
        b.Append(B("two"), T(1_001));
        a.Finish(0, T(1_002));
        b.Finish(0, T(1_002));
        var both = store.TotalBytes();
        Assert.True(both > 0);
        store.Delete("a");
        Assert.Equal(["b"], store.Entries().Select(e => e.Id));
        Assert.True(store.TotalBytes() < both);
        store.DeleteAll();
        Assert.Empty(store.Entries());
        Assert.Equal(0, store.TotalBytes());
    }

    [Fact]
    public void DeleteFinishedKeepsLiveWriters()
    {
        var store = Store();
        var done = Writer(store, "done");
        done.Append(B("x"), T(1_001));
        done.Finish(0, T(1_002));
        var running = Writer(store, "running", 2_000);
        store.DeleteFinished();
        Assert.Equal(["running"], store.Entries().Select(e => e.Id));
        foreach (var ext in new[] { "cast", "json" })
        {
            Assert.True(File.Exists(Path.Combine(_directory, $"running.{ext}")));
            Assert.False(File.Exists(Path.Combine(_directory, $"done.{ext}")));
        }
        running.Append(B("still"), T(2_001));
        running.Finish(0, T(2_002));
        Assert.Equal("still", S(store.Output("running")));
        store.DeleteFinished();
        Assert.Empty(store.Entries());
    }

    [Fact]
    public void PruneByAge()
    {
        var store = Store();
        Writer(store, "old", 1_000).Finish(0, T(2_000));
        Writer(store, "recent", 1_000).Finish(0, T(9_000));
        var live = Writer(store, "live", 500);
        live.Append(B("still here"), T(600));
        Assert.Equal(1, store.Prune(T(5_000)));
        Assert.Equal(new HashSet<string> { "recent", "live" }, store.Entries().Select(e => e.Id).ToHashSet());
        Assert.Equal(0, store.Prune(null)); // Forever keeps everything under the size cap
        Assert.Equal(1, store.Prune(DateTimeOffset.MaxValue)); // the live session is never pruned
        Assert.Equal(["live"], store.Entries().Select(e => e.Id));
        live.Append(B(" and recording"), T(700));
        Assert.EndsWith("still here and recording", S(store.Output("live")));
    }

    [Fact]
    public void PruneBySize()
    {
        var store = Store();
        string[] ids = ["a", "b", "c"];
        for (var i = 0; i < ids.Length; i++)
        {
            var writer = Writer(store, ids[i], 1_000);
            writer.Append(Enumerable.Repeat((byte)'x', 10_000).ToArray(), T(1_001));
            writer.Finish(0, T(2_000 + i));
        }
        var live = Writer(store, "live", 1);
        live.Append(Enumerable.Repeat((byte)'y', 10_000).ToArray(), T(2));
        var each = store.TotalBytes() / 4;
        Assert.Equal(2, store.Prune(null, each * 2 + each / 2));
        Assert.Equal(new HashSet<string> { "c", "live" }, store.Entries().Select(e => e.Id).ToHashSet());
        Assert.Equal(1, store.Prune(null, 0));
        Assert.Equal(["live"], store.Entries().Select(e => e.Id)); // even over the cap, a live session stays
    }

    [Fact]
    public void PruneNeitherBlocksNorDeletesASessionBegunMidScan()
    {
        var store = Store();
        Writer(store, "old", 1_000).Finish(0, T(2_000));
        TranscriptWriter? begun = null;
        store.AfterPruneSnapshot = () =>
        {
            var opened = Task.Run(() => begun = Writer(store, "new", 1_500));
            Assert.True(opened.Wait(TimeSpan.FromSeconds(5)), "begin waited on the prune");
        };
        Assert.Equal(1, store.Prune(DateTimeOffset.MaxValue, 0));
        store.AfterPruneSnapshot = null;
        Assert.NotNull(begun);
        Assert.Equal(["new"], store.Entries().Select(e => e.Id));
        begun!.Append(B("recorded"), T(1_501));
        Assert.Equal("recorded", S(store.Output("new")));
    }

    [Fact]
    public void PruneTakesAnUnendedLeftoverByItsLastWrite()
    {
        var store = Store();
        var writer = Writer(store, "crashed", 1_000);
        writer.Append(B("x"), T(1_001));
        writer.Cancel(); // as if the app had quit: no end recorded, nothing writing
        Assert.Equal(0, store.Prune(DateTimeOffset.UtcNow.AddHours(-1))); // written just now
        Assert.Equal(1, store.Prune(DateTimeOffset.UtcNow.AddMinutes(1)));
    }

    [Fact]
    public void WritesAfterDeleteRecreateNothing()
    {
        var store = Store();
        var a = Writer(store, "a");
        var b = Writer(store, "b");
        a.Append(B("x"), T(1_001));
        store.Delete("a");
        a.Append(B("y"), T(1_002));
        a.Finish(0, T(1_003));
        a.SetTitle("late");
        Assert.Equal(["b"], store.Entries().Select(e => e.Id));
        Assert.False(File.Exists(Path.Combine(_directory, "a.json")));
        Assert.False(File.Exists(Path.Combine(_directory, "a.cast")));

        store.DeleteAll();
        b.Append(B("y"), T(1_002));
        b.Finish(0, T(1_003));
        Assert.Empty(store.Entries());
        Assert.Empty(Directory.GetFileSystemEntries(_directory));
    }

    [Fact]
    public void IdsThatAreNotPlainNamesAreRejected()
    {
        var store = Store();
        foreach (var bad in new[] { "../x", "a/b", @"a\b", "C:x", "..", ".hidden", "trailing.", "CON", "nul.cast", "COM1", "lpt9", "", new string('a', 129), "a b" })
        {
            Assert.Throws<ArgumentException>(() => store.Output(bad));
            Assert.Throws<ArgumentException>(() => store.Begin(bad, "", "", 1, 1, T(0)));
        }
        Assert.True(TranscriptStore.IsSafeId("3F2504E0-4F89-11D3-9A0C-0305E82C3301"));
        Assert.True(TranscriptStore.IsSafeId("console"));
        var outside = Path.Combine(Path.GetDirectoryName(_directory)!, $"victim-{Guid.NewGuid():N}.json");
        File.WriteAllText(outside, "x");
        try
        {
            store.Delete("../" + Path.GetFileNameWithoutExtension(outside));
            store.Delete(@"..\" + Path.GetFileNameWithoutExtension(outside));
            Assert.True(File.Exists(outside));
        }
        finally { File.Delete(outside); }
    }

    [Fact]
    public void EmptyAndConcurrentAppends()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append([], T(1_001));
        Assert.Empty(store.Output("s1"));
        Parallel.For(0, 50, _ => writer.Append(B("ab"), T(1_001)));
        Assert.Equal(100, store.Output("s1").Length);
    }

    [Fact]
    public void SetTitleRewritesEntryAndSurvivesFinish()
    {
        var store = Store();
        var writer = Writer(store);
        writer.SetTitle("ls -la");
        Assert.Equal("ls -la", store.Entries()[0].Title);
        writer.Finish(0, T(1_002));
        Assert.Equal("ls -la", store.Entries()[0].Title);
    }

    [Fact]
    public void CastIsCappedWithAMarker()
    {
        const long limit = 4096;
        var store = Store(castLimit: limit);
        var writer = Writer(store);
        for (var i = 0; i < 200; i++) writer.Append(B($"line {i} xxxxxxxxxxxxxxxx\r\n"), T(1_001));
        writer.Append(B("after-the-cap"), T(1_002));
        writer.Finish(7, T(1_003));
        var size = new FileInfo(CastPath()).Length;
        Assert.True(size <= limit);
        var text = S(store.Output("s1"));
        Assert.StartsWith("line 0 ", text);
        Assert.EndsWith("[transcript truncated]\r\n", text);
        Assert.Equal(2, text.Split("[transcript truncated]").Length);
        Assert.DoesNotContain("after-the-cap", text);
        var entry = store.Entries()[0];
        Assert.Equal(7, entry.ExitStatus);
        Assert.Equal(1_003, entry.EndedAt);
        Assert.Equal(size, entry.Bytes);
    }

    [Fact]
    public void TailReadIsBoundedOnALargeCast()
    {
        var store = Store();
        var writer = Writer(store);
        var filler = new string('x', 4086);
        for (var i = 0; i < 6000; i++) writer.Append(B($"{i:D8}{filler}\r\n"), T(1_001));
        writer.Finish(0, T(1_002));
        const int maxBytes = 1 << 20;
        var (output, bytesRead) = TranscriptStore.TailFile(CastPath(), maxBytes);
        Assert.Equal(maxBytes, output.Length);
        Assert.EndsWith("00005999" + filler + "\r\n", S(output));
        Assert.True(bytesRead < maxBytes + (int)TranscriptStore.SizeCheckpoint + 2 * TranscriptStore.TailBlock, "only the end of the file is read");
        Assert.Equal(new Resize(80, 24), store.Replay("s1", maxBytes)[0]);
        Assert.Equal(output, store.Output("s1", maxBytes));
        Assert.Equal(TranscriptStore.ReadLimit, store.Output("s1").Length);
    }

    [Fact]
    public void TailStartsOnACharacter()
    {
        var store = Store();
        Writer(store).Append(B("€€€"), T(1_001));
        Assert.Equal("€", S(store.Output("s1", 4)));
    }

    [Fact]
    public void ResizeIsAnAsciicastResizeEvent()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append(B("a"), T(1_001));
        writer.Resize(48, 20, T(1_002));
        writer.Resize(48, 20, T(1_003)); // unchanged: not written
        writer.Append(B("b"), T(1_004));
        writer.Finish(0, T(1_005));
        var events = Lines().Skip(1).Select(l => JsonDocument.Parse(l).RootElement).ToList();
        Assert.Equal(["o", "r", "o"], events.Select(e => e[1].GetString()));
        Assert.Equal(2, events[1][0].GetDouble());
        Assert.Equal("48x20", events[1][2].GetString());
        Assert.Equal([new Resize(80, 24), O("a"), new Resize(48, 20), O("b")], store.Replay("s1"));
        Assert.Equal("ab", S(store.Output("s1")));
        Assert.Equal(80, store.Entries()[0].Cols);
        Assert.Equal(24, store.Entries()[0].Rows);
    }

    [Fact]
    public void ResizeInsideACharacterKeepsItWhole()
    {
        var store = Store();
        var writer = Writer(store);
        var euro = B("€");
        writer.Append(euro.AsSpan(0, 1), T(1_001));
        writer.Resize(40, 10, T(1_002));
        writer.Append(euro.AsSpan(1, 2), T(1_003));
        Assert.Equal([new Resize(40, 10), O("€")], store.Replay("s1"));
    }

    [Fact]
    public void TailStartsWithTheSizeInEffectAtTheCut()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append(B("0123456789"), T(1_001));
        writer.Resize(48, 20, T(1_002));
        writer.Append(B("abcdefghij"), T(1_003));
        writer.Append(B("ABCDEFGHIJ"), T(1_004));
        writer.Resize(100, 30, T(1_005));
        writer.Append(B("xyz"), T(1_006));
        Assert.Equal([new Resize(48, 20), O("fghijABCDEFGHIJ"), new Resize(100, 30), O("xyz")], store.Replay("s1", 18));
        // The Swift test's 32 depends on JSONSerialization's line lengths ("1" for a whole number, where .NET writes
        // the same); resize lines are 15 bytes here too, so the second resize's budget runs out at the same place.
        Assert.Equal([new Resize(80, 24), O("123456789"), new Resize(48, 20), O("abcdefghijABCDEFGHIJ"), new Resize(100, 30), O("xyz")],
            store.Replay("s1", 32));
        Assert.Equal([new Resize(100, 30), O("xyz")], store.Replay("s1", 3));
    }

    [Fact]
    public void SizeIsRestatedAtCheckpoints()
    {
        var store = Store(checkpoint: 1_000);
        var writer = Writer(store);
        writer.Resize(48, 20, T(1_001));
        for (var i = 0; i < 100; i++) writer.Append(B(new string('x', 100)), T(1_002));
        writer.Finish(0, T(1_003));
        var sizes = Lines().Where(l => l.Contains("\"r\"", StringComparison.Ordinal)).ToList();
        Assert.True(sizes.Count >= 8);
        Assert.All(sizes, l => Assert.EndsWith("\"48x20\"]", l));
        Assert.Equal(new Resize(48, 20), store.Replay("s1", 150)[0]);
    }

    [Fact]
    public void CastWithoutResizeEventsUsesTheHeader()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "old.cast"),
            "{\"version\":2,\"width\":48,\"height\":20,\"timestamp\":1000,\"title\":\"zsh\"}\n"
            + "[0.5,\"o\",\"dev@Office-PC ~ % \"]\n[1.0,\"o\",\"python --v\"]\n\n");
        var store = Store();
        Assert.Equal([new Resize(48, 20), O("dev@Office-PC ~ % python --v")], store.Replay("old"));
    }

    [Fact]
    public void CutInsideTheFirstOutputUsesTheHeaderAtTheStart()
    {
        var store = Store();
        var writer = Writer(store);
        writer.Append(B("0123456789"), T(1_001));
        writer.Finish(0, T(1_002));
        var (chunks, bytesRead) = TranscriptStore.ReplayFile(CastPath(), 4);
        Assert.Equal([new Resize(80, 24), O("6789")], chunks);
        Assert.Equal(new FileInfo(CastPath()).Length, bytesRead);
    }

    [Fact]
    public void HeaderOnlyCastReadIsBounded()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "big.cast");
        using (var file = File.Create(path))
        {
            file.Write(B("{\"version\":2,\"width\":48,\"height\":20,\"timestamp\":1000,\"title\":\"zsh\"}\n"));
            var line = B($"[1.0,\"o\",\"{new string('y', 4000)}\"]\n");
            for (var i = 0; i < 256 * 24; i++) file.Write(line);
        }
        const int maxBytes = 1 << 20;
        var (chunks, bytesRead) = TranscriptStore.ReplayFile(path, maxBytes);
        Assert.Equal(new Resize(48, 20), chunks[0]);
        Assert.Equal(2, chunks.Count);
        Assert.True(bytesRead < maxBytes + TranscriptStore.SizeSearchLimit + 3 * TranscriptStore.TailBlock);
    }

    [Fact]
    public void SizesAreClamped_AndConsecutiveResizesCoalesce()
    {
        var store = Store();
        var writer = store.Begin("s1", "zsh", "Pixel", 0, 5000, T(1_000));
        writer.Append(B("a"), T(1_001));
        writer.Resize(5000, 0, T(1_002));
        writer.Append(B("b"), T(1_003));
        Assert.Equal([new Resize(1, 1000), O("a"), new Resize(1000, 1), O("b")], store.Replay("s1"));

        var other = Writer(store, "s2");
        other.Append(B("a"), T(1_001));
        for (var rows = 10; rows < 20; rows++) other.Resize(48, rows, T(1_002));
        other.Append(B("b"), T(1_003));
        Assert.Equal([new Resize(80, 24), O("a"), new Resize(48, 19), O("b")], store.Replay("s2"));
    }

    [Fact]
    public void EntriesFollowChanges()
    {
        var store = Store();
        var a = Writer(store, "a");
        Writer(store, "b", 2_000);
        Assert.Equal(["b", "a"], store.Entries().Select(e => e.Id));
        a.SetTitle("renamed");
        a.Append(B("abc"), T(1_001));
        store.Delete("b");
        var entries = store.Entries();
        Assert.Equal(["a"], entries.Select(e => e.Id));
        Assert.Equal("renamed", entries[0].Title);
        Assert.True(entries[0].Bytes > 0, "sizes are current even when the entry is not re-read");
    }
}

/// <summary>A port of ShellReplayTests.swift.</summary>
public class ShellReplayTests
{
    private static byte[] B(string text) => Encoding.UTF8.GetBytes(text);
    private static string S(string? base64) => Encoding.UTF8.GetString(Convert.FromBase64String(base64 ?? ""));

    private static readonly ShellReplayChunk[] Recording =
    [
        new Resize(48, 20), new Output(B("dev@Office-PC ~ % ")), new Output(B("python --v")), new Output(B("v \r\u001b[K")), new Output(B("ersion\r\n")),
    ];

    [Fact]
    public void SizeStrings_LargestGrid_FitScale()
    {
        Assert.Equal("48x20", ShellReplay.SizeString(48, 20));
        Assert.Equal((48, 20), ShellReplay.ParseSize("48x20"));
        foreach (var bad in new[] { "", "48", "48x", "x20", "0x20", "48x0", "-1x5", "48x20x1", "1001x20", "a x b" })
            Assert.Null(ShellReplay.ParseSize(bad));
        Assert.Null(ShellReplay.LargestGrid([new Output(B("x"))]));
        Assert.Equal((100, 40), ShellReplay.LargestGrid([new Resize(48, 40), new Output([]), new Resize(100, 20)]));
        Assert.Equal(1, ShellReplay.FitScale(300, 300, 600, 600, 0.5));
        Assert.Equal(0.75, ShellReplay.FitScale(800, 300, 600, 600, 0.5));
        Assert.Equal(0.5, ShellReplay.FitScale(300, 1200, 600, 600, 0.4));
        Assert.Equal(0.5, ShellReplay.FitScale(6000, 300, 600, 600, 0.5));
        Assert.Equal(1, ShellReplay.FitScale(300, 300, 0, 600, 0.5));
    }

    [Fact]
    public void TranscriptLinesCarrySizesAndRoundTrip()
    {
        var lines = ShellReplay.TranscriptLines("s", Recording);
        Assert.Equal(48, lines[0].Cols);
        Assert.Equal(20, lines[0].Rows);
        Assert.All(lines.Skip(1), l => Assert.Null(l.Cols));
        Assert.True(lines[^1].Done);
        Assert.All(lines.SkipLast(1), l => Assert.Null(l.Done));
        var collector = new ShellReplay.Collector();
        foreach (var line in lines)
        {
            var encoded = line.EncodeLine();
            var decoded = ShellEnvelope.Decode(encoded.AsSpan(0, encoded.Length - 1));
            collector.Add(Convert.FromBase64String(decoded.Data!), decoded.Cols, decoded.Rows);
        }
        var joined = Recording.OfType<Output>().SelectMany(o => o.Data).ToArray();
        Assert.Equal([new Resize(48, 20), new Output(joined)], collector.Chunks);
    }

    [Fact]
    public void TranscriptLinesSplitOutputAndKeepResizesInPlace()
    {
        ShellReplayChunk[] chunks = [new Resize(80, 24), new Output(B("abcde")), new Resize(40, 10), new Resize(41, 11), new Output(B("fg")), new Resize(50, 12)];
        var lines = ShellReplay.TranscriptLines("s", chunks, chunkSize: 2);
        Assert.Equal(["ab", "cd", "e", "fg", ""], lines.Select(l => S(l.Data)));
        Assert.Equal([80, null, null, 41, 50], lines.Select(l => l.Cols));
        Assert.Equal([24, null, null, 11, 12], lines.Select(l => l.Rows));
        Assert.Equal([null, null, null, null, true], lines.Select(l => l.Done));
        Assert.All(lines, l => { Assert.Equal("s", l.Session); Assert.Equal(ShellEnvelope.TranscriptData, l.T); });
        var collector = new ShellReplay.Collector();
        foreach (var line in lines) collector.Add(Convert.FromBase64String(line.Data ?? ""), line.Cols, line.Rows);
        Assert.Equal([new Resize(80, 24), new Output(B("abcde")), new Resize(41, 11), new Output(B("fg")), new Resize(50, 12)], collector.Chunks);
    }

    [Fact]
    public void SmallOutputIsJoined_EmptyIsOneDoneLine_AndSizesAreOptional()
    {
        ShellReplayChunk[] chunks = [new Resize(48, 20), .. "abcde".Select(c => new Output(B(c.ToString())))];
        var lines = ShellReplay.TranscriptLines("s", chunks, chunkSize: 2);
        Assert.Equal(["ab", "cd", "e"], lines.Select(l => S(l.Data)));
        Assert.Equal([48, null, null], lines.Select(l => l.Cols));

        var empty = ShellReplay.TranscriptLines("s", []);
        Assert.Single(empty);
        Assert.Equal("", empty[0].Data);
        Assert.True(empty[0].Done);
        Assert.Null(empty[0].Cols);

        var collector = new ShellReplay.Collector();
        collector.Add(B("a"));
        collector.Add(B("b"), 0, 5); // invalid: ignored
        Assert.Equal([new Output(B("ab"))], collector.Chunks);
        Assert.Null(ShellReplay.LargestGrid(collector.Chunks));
    }
}
