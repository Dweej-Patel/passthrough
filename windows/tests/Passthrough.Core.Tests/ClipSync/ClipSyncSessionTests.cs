using System.Text;
using System.Threading.Channels;
using Passthrough.Core.ClipSync;
using Passthrough.Core.Tests.Pipe;
using Xunit;

namespace Passthrough.Core.Tests.ClipSync;

public sealed class ClipSyncSessionTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "pt-clip-" + Guid.NewGuid().ToString("N"));
    private static readonly TimeSpan Limit = TimeSpan.FromSeconds(10);

    public ClipSyncSessionTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); }
        catch (IOException) { }
    }

    /// <summary>One end of a session, with what it reported.</summary>
    private sealed class Side
    {
        public required ClipSyncSession Session;
        public required Task Run;
        public readonly Channel<ClipEvent> Events = Channel.CreateUnbounded<ClipEvent>();
        public string Staging = "";

        /// <summary>The next event of type <typeparamref name="T"/>; others before it are passed over.</summary>
        public async Task<T> Next<T>() where T : ClipEvent
        {
            using var limit = new CancellationTokenSource(Limit);
            while (true)
            {
                var e = await Events.Reader.ReadAsync(limit.Token);
                if (e is T wanted) return wanted;
            }
        }
    }

    private (Side Viewer, Side Host) Pair(Func<ulong?>? hostRoom = null)
    {
        var (a, b) = DuplexStreams.Create();
        return (Make(a, "viewer", false, null), Make(b, "host", true, hostRoom));
    }

    private Side Make(Stream stream, string name, bool acceptDrops, Func<ulong?>? room)
    {
        var staging = Path.Combine(_root, name);
        var events = Channel.CreateUnbounded<ClipEvent>();
        var session = new ClipSyncSession(stream, default, new ClipSyncOptions { Staging = staging, AcceptDrops = acceptDrops, Room = room ?? (() => null) },
            e => events.Writer.TryWrite(e));
        var side = new Side { Session = session, Run = null!, Staging = staging };
        _ = Task.Run(async () => { await foreach (var e in events.Reader.ReadAllAsync()) side.Events.Writer.TryWrite(e); });
        side.Run = session.RunAsync();
        return side;
    }

    /// <summary>A host session fed raw bytes by the test, and what it wrote back.</summary>
    private (Side Host, Stream Peer, ClipSyncWire.Reader FromHost) Raw(Func<ulong?>? room = null, bool acceptDrops = true)
    {
        var (a, b) = DuplexStreams.Create();
        return (Make(b, "host", acceptDrops, room), a, new ClipSyncWire.Reader(a));
    }

    private static Task Write(Stream peer, params ClipMessage[] messages) => peer.WriteAsync(messages.SelectMany(ClipSyncWire.Encode).ToArray()).AsTask();

    private static async Task<T> Read<T>(ClipSyncWire.Reader reader) where T : ClipMessage
    {
        using var limit = new CancellationTokenSource(Limit);
        while (true)
        {
            var m = await reader.ReadAsync(limit.Token) ?? throw new EndOfStreamException();
            if (m is T wanted) return wanted;
        }
    }

    private static ClipMessage Offer(uint transfer, ClipKind kind, uint count, ulong total) => new ClipMessage.Offer(new ClipOffer(transfer, kind, 0, 0, count, total));
    private static ClipMessage Item(uint transfer, uint index, ClipFormat format, ulong size, string name = "") =>
        new ClipMessage.Item(transfer, index, new ClipWireItem((byte)format, size, name));
    private static ClipMessage Data(uint transfer, uint item, string text) => new ClipMessage.Data(transfer, item, Encoding.UTF8.GetBytes(text));

    [Fact]
    public async Task ACopy_LandsOnTheOtherSide_AndItsResultComesBack()
    {
        var (viewer, host) = Pair();
        var png = new byte[700_000];
        Random.Shared.NextBytes(png);
        var id = viewer.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Text, "héllo\r\n"u8.ToArray()), ClipItem.Inline(ClipFormat.Png, png)]), ClipKind.Clipboard);
        var received = (await host.Next<ClipEvent.Received>()).Transfer;
        Assert.Equal(ClipKind.Clipboard, received.Kind);
        Assert.Equal("héllo\r\n", Encoding.UTF8.GetString(received.Data(ClipFormat.Text)!));
        Assert.Equal(png, received.Data(ClipFormat.Png));
        Assert.Null(received.Folder);
        await viewer.Next<ClipEvent.Sent>();
        host.Session.Result(received.Transfer, ClipResult.Placed);
        Assert.Equal(new ClipEvent.Outcome(id, ClipResult.Placed), await viewer.Next<ClipEvent.Outcome>());

        // And the other way, on the same connection.
        host.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Text, "back"u8.ToArray())]), ClipKind.Clipboard);
        Assert.Equal("back", Encoding.UTF8.GetString((await viewer.Next<ClipEvent.Received>()).Transfer.Data(ClipFormat.Text)!));

        viewer.Session.Close();
        await viewer.Run.WaitAsync(Limit);
        await host.Run.WaitAsync(Limit);
        Assert.Null((await host.Next<ClipEvent.Closed>()).Error);
    }

    [Fact]
    public async Task DroppedFilesAndFolders_ArriveWhole_UnderNamesThisPcCanHold()
    {
        var source = Path.Combine(_root, "source");
        Directory.CreateDirectory(Path.Combine(source, "Docs", "Empty"));
        var big = new byte[600_000];
        Random.Shared.NextBytes(big);
        File.WriteAllBytes(Path.Combine(source, "Docs", "big.bin"), big);
        File.WriteAllText(Path.Combine(source, "Docs", "note.txt"), "a note");
        File.WriteAllBytes(Path.Combine(source, "empty.dat"), []);
        var (payload, failed) = ClipFiles.Collect([Path.Combine(source, "Docs"), Path.Combine(source, "empty.dat")]);
        Assert.Null(failed);
        Assert.Equal(["Docs", "Docs/Empty", "Docs/big.bin", "Docs/note.txt", "empty.dat"], payload!.Items.Select(i => i.Name));
        // What a Mac may name a file: this PC renames the parts it can't hold.
        var items = payload.Items.Append(new ClipItem(ClipFormat.File, "Why?.txt", 6, default, Path.Combine(source, "Docs", "note.txt")))
            .Append(new ClipItem(ClipFormat.File, "why_.TXT", 6, default, Path.Combine(source, "Docs", "note.txt"))).ToList();

        var (viewer, host) = Pair();
        viewer.Session.Send(new ClipPayload(items), ClipKind.Drop, 100, 200);
        var incoming = await host.Next<ClipEvent.Incoming>();
        Assert.Equal((ClipKind.Drop, (ushort)100, (ushort)200), (incoming.Kind, incoming.X, incoming.Y));
        var received = (await host.Next<ClipEvent.Received>()).Transfer;
        var folder = received.Folder!;
        Assert.StartsWith(host.Staging, folder);
        Assert.Equal(big, File.ReadAllBytes(Path.Combine(folder, "Docs", "big.bin")));
        Assert.Equal("a note", File.ReadAllText(Path.Combine(folder, "Docs", "note.txt")));
        Assert.True(Directory.Exists(Path.Combine(folder, "Docs", "Empty")));
        Assert.Equal(0, new FileInfo(Path.Combine(folder, "empty.dat")).Length);
        Assert.Equal("a note", File.ReadAllText(Path.Combine(folder, "Why_.txt")));
        Assert.Equal("a note", File.ReadAllText(Path.Combine(folder, "why_ 2.TXT")));
        Assert.Equal(4, received.TopLevel.Count);
        Assert.Equal((100, 200), (received.X, received.Y));
        // Passed on to another viewer under the names it came with.
        Assert.Contains(received.ToPayload().Items, i => i.Name == "Why?.txt" && i.Size == 6);
    }

    [Fact]
    public async Task AViewer_TakesNoDropFromItsHost()
    {
        var (viewer, host) = Pair();
        var id = host.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Text, "x"u8.ToArray())]), ClipKind.Drop);
        Assert.Equal(new ClipEvent.Declined(id, ClipDecline.BadOffer), await host.Next<ClipEvent.Declined>());
        Assert.False(Directory.Exists(viewer.Staging));
    }

    [Fact]
    public async Task AFileThatChangedSinceTheOffer_IsAbandoned_NotPaddedOrCut()
    {
        var file = Path.Combine(_root, "short.txt");
        File.WriteAllText(file, "four");
        var (viewer, host) = Pair();
        foreach (var claimed in new ulong[] { 10, 2 })
        {
            var id = viewer.Session.Send(new ClipPayload([new ClipItem(ClipFormat.File, "short.txt", claimed, default, file)]), ClipKind.Drop);
            Assert.Equal(new ClipEvent.Declined(id, ClipDecline.Failed), await viewer.Next<ClipEvent.Declined>());
            Assert.Equal(id, (await host.Next<ClipEvent.IncomingEnded>()).Transfer);
        }
        Assert.Empty(Directory.GetDirectories(host.Staging));
    }

    [Fact]
    public async Task ANewerCopy_ReplacesOneStillComing_AndWhatIsInFlightIsSkipped()
    {
        var (host, peer, _) = Raw();
        await Write(peer, Offer(1, ClipKind.Clipboard, 1, 10), Item(1, 0, ClipFormat.Text, 10), Data(1, 0, "half"),
            Offer(2, ClipKind.Clipboard, 1, 3), Data(1, 0, "-more"), new ClipMessage.Done(1), Item(2, 0, ClipFormat.Text, 3), Data(2, 0, "new"), new ClipMessage.Done(2));
        Assert.Equal(1u, (await host.Next<ClipEvent.IncomingEnded>()).Transfer);
        var received = (await host.Next<ClipEvent.Received>()).Transfer;
        Assert.Equal((2u, "new"), (received.Transfer, Encoding.UTF8.GetString(received.Data(ClipFormat.Text)!)));
    }

    [Fact]
    public async Task AnOfferOfAnUnknownKind_IsDeclined_AndACopyInFlightStillLands()
    {
        var (host, peer, fromHost) = Raw();
        await Write(peer, Offer(1, ClipKind.Clipboard, 1, 4), Item(1, 0, ClipFormat.Text, 4), Data(1, 0, "ab"));
        await peer.WriteAsync(Convert.FromHexString("02" + "00000015" + "00000002" + "07" + "00000000" + "00000001" + "0000000000000001"));
        Assert.Equal(new ClipMessage.Decline(2, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        await Write(peer, Data(1, 0, "cd"), new ClipMessage.Done(1));
        Assert.Equal("abcd", Encoding.UTF8.GetString((await host.Next<ClipEvent.Received>()).Transfer.Data(ClipFormat.Text)!));
    }

    [Fact]
    public async Task MoreBytesThanAnItemSaid_OrAnItemCutShort_DeclinesTheTransfer()
    {
        var (host, peer, fromHost) = Raw();
        await Write(peer, Offer(1, ClipKind.Drop, 1, 3), Item(1, 0, ClipFormat.File, 3, "a.txt"), Data(1, 0, "four"));
        Assert.Equal(new ClipMessage.Decline(1, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        // Bytes still in flight for it are skipped, silently.
        await Write(peer, Data(1, 0, "x"), new ClipMessage.Done(1));
        await Write(peer, Offer(2, ClipKind.Drop, 2, 6), Item(2, 0, ClipFormat.File, 3, "a.txt"), Data(2, 0, "ab"), Item(2, 1, ClipFormat.File, 3, "b.txt"));
        Assert.Equal(new ClipMessage.Decline(2, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        await Write(peer, Offer(3, ClipKind.Drop, 1, 3), Item(3, 0, ClipFormat.File, 3, "a.txt"), Data(3, 0, "ab"), new ClipMessage.Done(3));
        Assert.Equal(new ClipMessage.Decline(3, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        // Data for an item that was never announced.
        await Write(peer, Offer(4, ClipKind.Drop, 1, 3), Data(4, 0, "abc"));
        Assert.Equal(new ClipMessage.Decline(4, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        Assert.Empty(Directory.GetDirectories(host.Staging));
    }

    [Fact]
    public async Task NoNameReachesOutsideTheTransfersFolder()
    {
        var (host, peer, fromHost) = Raw();
        uint transfer = 0;
        foreach (var name in new[] { "../x", "..", "a/../../x", "../́x", "C:x", "\\\\server\\share", "/etc/x", "a\u0000b" })
        {
            await Write(peer, Offer(++transfer, ClipKind.Drop, 1, 1), Item(transfer, 0, ClipFormat.File, 1, name), Data(transfer, 0, "x"), new ClipMessage.Done(transfer));
            Assert.Equal(new ClipMessage.Decline(transfer, ClipDecline.BadOffer), await Read<ClipMessage.Decline>(fromHost));
        }
        Assert.Empty(Directory.Exists(host.Staging) ? Directory.GetFileSystemEntries(host.Staging) : []);
        Assert.Empty(Directory.GetFileSystemEntries(_root));
    }

    [Fact]
    public async Task AFifthTransferAtOnce_IsDeclined_AndRoomCountsWhatIsStillComing()
    {
        var (host, peer, fromHost) = Raw(room: () => 100);
        for (uint t = 1; t <= 4; t++) await Write(peer, Offer(t, ClipKind.Drop, 1, 20));
        await Write(peer, Offer(5, ClipKind.Drop, 1, 1));
        Assert.Equal(new ClipMessage.Decline(5, ClipDecline.NoRoom), await Read<ClipMessage.Decline>(fromHost));
        // One finishes: there is a place again, but only 100 - 3 x 20 bytes of room.
        await Write(peer, Item(1, 0, ClipFormat.File, 20, "a"), Data(1, 0, new string('x', 20)), new ClipMessage.Done(1));
        await host.Next<ClipEvent.Received>();
        await Write(peer, Offer(6, ClipKind.Drop, 1, 41));
        Assert.Equal(new ClipMessage.Decline(6, ClipDecline.NoRoom), await Read<ClipMessage.Decline>(fromHost));
        await Write(peer, Offer(7, ClipKind.Drop, 1, 40), Item(7, 0, ClipFormat.File, 40, "b"), Data(7, 0, new string('y', 40)), new ClipMessage.Done(7));
        Assert.Equal(7u, (await host.Next<ClipEvent.Received>()).Transfer.Transfer);
    }

    [Fact]
    public async Task AnInlineItemOverItsSize_IsDeclinedWhateverTheKind_AndOldNumbersAreIgnored()
    {
        var (host, peer, fromHost) = Raw();
        await Write(peer, Offer(5, ClipKind.Drop, 1, ClipSyncWire.MaxClipboardText + 1), Item(5, 0, ClipFormat.Text, ClipSyncWire.MaxClipboardText + 1));
        Assert.Equal(new ClipMessage.Decline(5, ClipDecline.TooLarge), await Read<ClipMessage.Decline>(fromHost));
        // A number that went down is not an offer; the one after it is.
        await Write(peer, Offer(3, ClipKind.Clipboard, 1, 1), Item(3, 0, ClipFormat.Text, 1), Data(3, 0, "x"), new ClipMessage.Done(3),
            Offer(6, ClipKind.Clipboard, 1, 1), Item(6, 0, ClipFormat.Text, 1), Data(6, 0, "y"), new ClipMessage.Done(6));
        Assert.Equal(6u, (await host.Next<ClipEvent.Received>()).Transfer.Transfer);
    }

    [Fact]
    public async Task AnOverlongPayload_EndsTheSession_AndWhatWasComingIsThrownAway()
    {
        var (host, peer, _) = Raw();
        await Write(peer, Offer(1, ClipKind.Drop, 1, 3), Item(1, 0, ClipFormat.File, 3, "a.txt"), Data(1, 0, "ab"));
        await host.Next<ClipEvent.Incoming>();
        var header = new byte[5];
        header[0] = 3;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(1), ClipSyncWire.MaxPayload + 1);
        await peer.WriteAsync(header);
        Assert.IsType<ClipPayloadTooLargeException>((await host.Next<ClipEvent.Closed>()).Error);
        await host.Run.WaitAsync(Limit);
        Assert.Empty(Directory.GetDirectories(host.Staging));
    }

    [Fact]
    public async Task ANewCopy_AbandonsThisSidesUnfinishedOne_NeverADrop()
    {
        var (peer, end) = DuplexStreams.Create();
        // The first item announced is held back: by then that copy's offer is out.
        var gate = new Fakes.GatedStream(end, w => w.Span[0] == 8);
        var host = Make(gate, "host", true, null);
        var reader = new ClipSyncWire.Reader(peer);
        var big = new byte[ClipSyncWire.MaxChunk * 3];
        var first = host.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Png, big)]), ClipKind.Clipboard);
        await gate.Held.WaitAsync(Limit);
        var drop = host.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Png, big)]), ClipKind.Drop);
        var second = host.Session.Send(new ClipPayload([ClipItem.Inline(ClipFormat.Text, "newer"u8.ToArray())]), ClipKind.Clipboard);
        gate.Release();
        var seen = new List<ClipMessage>();
        while (seen.OfType<ClipMessage.Done>().Count() < 2) seen.Add(await Read<ClipMessage>(reader));
        Assert.Contains(new ClipMessage.Abandon(first), seen);
        Assert.DoesNotContain(new ClipMessage.Done(first), seen);
        Assert.Contains(new ClipMessage.Done(second), seen);
        Assert.Contains(new ClipMessage.Done(drop), seen);
        Assert.DoesNotContain(new ClipMessage.Abandon(drop), seen);
        // Nothing of the abandoned copy follows its abandon.
        var at = seen.IndexOf(new ClipMessage.Abandon(first));
        Assert.DoesNotContain(seen.Skip(at + 1), m => m is ClipMessage.Data d && d.Transfer == first);
    }
}
