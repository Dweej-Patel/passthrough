using System.Text.Json;
using Passthrough.Core.ClipSync;
using Xunit;

namespace Passthrough.Core.Tests.ClipSync;

/// <summary>Clipboard sync's wire against the <c>clipSync</c> section of protocol/fixtures.json.</summary>
public class ClipSyncWireTests
{
    private static readonly JsonElement C = Fixtures.Root.GetProperty("clipSync");

    private static ClipMessage FromFixture(JsonElement m) => m.GetProperty("name").GetString() switch
    {
        "hello" => new ClipMessage.Hello(m.GetProperty("version").GetByte()),
        "offer" => new ClipMessage.Offer(new ClipOffer(m.GetProperty("transfer").GetUInt32(), (ClipKind)m.GetProperty("kind").GetByte(),
            m.GetProperty("x").GetUInt16(), m.GetProperty("y").GetUInt16(), m.GetProperty("count").GetUInt32(), m.GetProperty("total").GetUInt64())),
        "item" => new ClipMessage.Item(m.GetProperty("transfer").GetUInt32(), m.GetProperty("index").GetUInt32(),
            new ClipWireItem(m.GetProperty("format").GetByte(), m.GetProperty("size").GetUInt64(), m.GetProperty("itemName").GetString())),
        "data" => new ClipMessage.Data(m.GetProperty("transfer").GetUInt32(), m.GetProperty("item").GetUInt32(), Convert.FromHexString(m.GetProperty("bytes").GetString()!)),
        "done" => new ClipMessage.Done(m.GetProperty("transfer").GetUInt32()),
        "abandon" => new ClipMessage.Abandon(m.GetProperty("transfer").GetUInt32()),
        "decline" => new ClipMessage.Decline(m.GetProperty("transfer").GetUInt32(), (ClipDecline)m.GetProperty("reason").GetByte()),
        "result" => new ClipMessage.Result(m.GetProperty("transfer").GetUInt32(), (ClipResult)m.GetProperty("status").GetByte()),
        var other => throw new InvalidOperationException(other),
    };

    [Fact]
    public void Constants_MatchFixtures()
    {
        Assert.Equal(ClipSyncWire.MaxPayload, C.GetProperty("maxPayload").GetInt32());
        Assert.Equal(ClipSyncWire.MaxChunk, C.GetProperty("maxChunk").GetInt32());
        Assert.Equal(ClipSyncWire.MaxOpenTransfers, C.GetProperty("maxOpenTransfers").GetInt32());
    }

    [Fact]
    public async Task Messages_EncodeToTheFixturesBytes_AndReadBack()
    {
        foreach (var m in C.GetProperty("messages").EnumerateArray())
        {
            var message = FromFixture(m);
            var hex = m.GetProperty("hex").GetString()!;
            Assert.Equal(hex, Convert.ToHexString(ClipSyncWire.Encode(message)).ToLowerInvariant());
            var read = await new ClipSyncWire.Reader(new MemoryStream(Convert.FromHexString(hex))).ReadAsync();
            if (message is ClipMessage.Data d)
            {
                var got = Assert.IsType<ClipMessage.Data>(read);
                Assert.Equal((d.Transfer, d.ItemIndex), (got.Transfer, got.ItemIndex));
                Assert.Equal(d.Bytes.ToArray(), got.Bytes.ToArray());
            }
            else Assert.Equal(message, read);
        }
    }

    [Fact]
    public async Task Reader_SkipsWhatItDoesntKnow_AndRefusesAnOverlongPayload()
    {
        // An unknown type, a known type cut short, an offer of an unknown kind, then hello; extra bytes after a layout are ignored.
        var bytes = Convert.FromHexString("63" + "00000001" + "ff" + "04" + "00000002" + "0000" + "02" + "00000015" + "00000009" + "07" + "00000000" + "00000001" + "0000000000000001"
            + "01" + "00000003" + "020000");
        var reader = new ClipSyncWire.Reader(new MemoryStream(bytes));
        Assert.Equal(new ClipMessage.Unknown(0x63), await reader.ReadAsync());
        Assert.Equal(new ClipMessage.Unknown(4), await reader.ReadAsync());
        Assert.Equal(new ClipMessage.UnknownOffer(9), await reader.ReadAsync());
        Assert.Equal(new ClipMessage.Hello(2), await reader.ReadAsync());
        Assert.Null(await reader.ReadAsync());

        var tooLong = new byte[5];
        tooLong[0] = 3;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(tooLong.AsSpan(1), ClipSyncWire.MaxPayload + 1);
        await Assert.ThrowsAsync<ClipPayloadTooLargeException>(() => new ClipSyncWire.Reader(new MemoryStream(tooLong)).ReadAsync());
        await Assert.ThrowsAsync<EndOfStreamException>(() => new ClipSyncWire.Reader(new MemoryStream(Convert.FromHexString("0400000004"))).ReadAsync());
    }

    [Fact]
    public void Decode_ANameThatIsntUtf8_HasNoName()
    {
        var payload = Convert.FromHexString("00000001" + "00000000" + "10" + "0000000000000000" + "0002" + "c328");
        var item = Assert.IsType<ClipMessage.Item>(ClipSyncWire.Decode(8, payload));
        Assert.Null(item.Value.Name);
        Assert.Equal(ClipDecline.BadOffer, new ClipSyncWire.ItemCheck(new ClipOffer(1, ClipKind.Drop, 0, 0, 1, 0)).Refusal(item.Value, 0));
    }

    [Fact]
    public void Decode_AnUnknownReasonOrStatus_ReadsAsFailed()
    {
        Assert.Equal(new ClipMessage.Decline(1, ClipDecline.Failed), ClipSyncWire.Decode(6, Convert.FromHexString("0000000109")));
        Assert.Equal(new ClipMessage.Decline(1, ClipDecline.Failed), ClipSyncWire.Decode(6, Convert.FromHexString("0000000100")));
        Assert.Equal(new ClipMessage.Result(1, ClipResult.Failed), ClipSyncWire.Decode(7, Convert.FromHexString("0000000109")));
    }

    [Fact]
    public void Names_MatchFixtures()
    {
        foreach (var n in C.GetProperty("validNames").EnumerateArray()) Assert.True(ClipSyncWire.IsValidName(n.GetString()), n.GetString());
        foreach (var n in C.GetProperty("invalidNames").EnumerateArray()) Assert.False(ClipSyncWire.IsValidName(n.GetString()), JsonSerializer.Serialize(n.GetString()));
        Assert.False(ClipSyncWire.IsValidName(null));
    }

    private static ClipDecline? Reason(JsonElement e) => e.GetProperty("decline") is { ValueKind: JsonValueKind.Number } n ? (ClipDecline)n.GetByte() : null;

    [Fact]
    public void Offers_MatchFixtures()
    {
        foreach (var o in C.GetProperty("offers").EnumerateArray())
        {
            var offer = new ClipOffer(1, (ClipKind)o.GetProperty("kind").GetByte(), 0, 0, o.GetProperty("count").GetUInt32(), o.GetProperty("total").GetUInt64());
            Assert.Equal(Reason(o), ClipSyncWire.Refusal(offer, room: ulong.MaxValue));
        }
        // A drop counts its bytes and 4096 for each item against the room; a copy counts its bytes.
        Assert.Equal(ClipDecline.NoRoom, ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Drop, 0, 0, 2, 10), room: 10 + 2 * 4096 - 1));
        Assert.Null(ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Drop, 0, 0, 2, 10), room: 10 + 2 * 4096));
        Assert.Equal(ClipDecline.NoRoom, ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Clipboard, 0, 0, 2, 11), room: 10));
        Assert.Null(ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Clipboard, 0, 0, 2, 10), room: 10));
        // Room that can't be read: no drop is taken (it has no limit of its own); a copy still is (it has).
        Assert.Equal(ClipDecline.NoRoom, ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Drop, 0, 0, 1, 1), room: null));
        Assert.Null(ClipSyncWire.Refusal(new ClipOffer(1, ClipKind.Clipboard, 0, 0, 1, 1), room: null));
        Assert.Equal(ulong.MaxValue, ClipSyncWire.Footprint(new ClipOffer(1, ClipKind.Drop, 0, 0, 2, ulong.MaxValue - 5)));
    }

    [Fact]
    public void Transfers_MatchFixtures()
    {
        foreach (var t in C.GetProperty("transfers").EnumerateArray())
        {
            var name = t.GetProperty("name").GetString();
            var check = new ClipSyncWire.ItemCheck(new ClipOffer(1, (ClipKind)t.GetProperty("kind").GetByte(), 0, 0, t.GetProperty("count").GetUInt32(), t.GetProperty("total").GetUInt64()));
            var declined = false;
            foreach (var i in t.GetProperty("items").EnumerateArray())
            {
                var item = new ClipWireItem(i.GetProperty("format").GetByte(), i.GetProperty("size").GetUInt64(), i.GetProperty("name").GetString());
                var refusal = check.Refusal(item, i.GetProperty("index").GetUInt32());
                Assert.True(Reason(i) == refusal, $"{name}: item {i.GetProperty("index")} answered {refusal}");
                declined |= refusal is not null;
            }
            Assert.True(t.GetProperty("complete").GetBoolean() == (!declined && check.IsComplete), name);
        }
    }

    [Fact]
    public void WindowsPart_RenamesWhatWindowsCantHold()
    {
        Assert.Equal("What_.txt", ClipNames.WindowsPart("What?.txt"));
        Assert.Equal("a_b_c_d_e_f", ClipNames.WindowsPart("a<b>c\"d|e*f"));
        Assert.Equal("trailing", ClipNames.WindowsPart("trailing. "));
        Assert.Equal("_", ClipNames.WindowsPart("..."));
        Assert.Equal("_CON", ClipNames.WindowsPart("CON"));
        Assert.Equal("_nul.txt", ClipNames.WindowsPart("nul.txt"));
        Assert.Equal("_COM1.tar.gz", ClipNames.WindowsPart("COM1.tar.gz"));
        Assert.Equal("CONSOLE", ClipNames.WindowsPart("CONSOLE"));
        Assert.Equal("_COM².log", ClipNames.WindowsPart("COM².log"));
        // What turns a name's letters around on screen: "photo<RLO>gpj.exe" would read "photoexe.jpg".
        Assert.Equal("photo_gpj.exe", ClipNames.WindowsPart("photo‮gpj.exe"));
        Assert.Equal("a_b_c", ClipNames.WindowsPart("a⁦b⁩c"));
        Assert.Equal("ordinary.txt", ClipNames.WindowsPart("ordinary.txt"));
        var longName = ClipNames.WindowsPart(new string('日', 300) + ".txt");
        Assert.Equal(ClipNames.MaxWindowsPart, longName.Length);
        Assert.EndsWith(".txt", longName);
        // Numbered to be unique, it still fits in what Windows takes.
        var numbered = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < 1200; i++) Assert.InRange(ClipNames.Unique(longName, numbered).Length, 1, 255);
    }

    [Fact]
    public void WirePart_IsAlwaysANameTheWireTakes()
    {
        foreach (var part in new[] { "a", "", ".", "..", "a:b", "a\\b/c", "tab\there", new string('日', 255) + ".jpeg", new string('x', 400), "é" })
        {
            var wire = ClipNames.WirePart(part);
            Assert.True(ClipSyncWire.IsValidName(wire), wire);
            Assert.DoesNotContain('/', wire);
        }
        Assert.Equal("é", ClipNames.WirePart("é"));
        Assert.EndsWith(".jpeg", ClipNames.WirePart(new string('日', 255) + ".jpeg"));
    }

    [Fact]
    public void Unique_NumbersNamesThatAreTheSameFile()
    {
        var taken = new HashSet<string>(StringComparer.Ordinal);
        Assert.Equal("a.txt", ClipNames.Unique("a.txt", taken));
        Assert.Equal("A 2.TXT", ClipNames.Unique("A.TXT", taken));
        Assert.Equal("a 3.txt", ClipNames.Unique("a.txt", taken));
        Assert.Equal("a 2 2.txt", ClipNames.Unique("a 2.txt", taken));
        Assert.Equal("é 2", ClipNames.Unique("é", new HashSet<string>(StringComparer.Ordinal) { ClipSyncWire.ItemCheck.Key("É") }));
    }
}
