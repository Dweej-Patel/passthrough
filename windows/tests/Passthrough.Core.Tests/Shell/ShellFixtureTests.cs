using System.Text;
using System.Text.Json;
using Passthrough.Core.Protocol;
using Passthrough.Core.Shell;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>
/// The remote shell protocol against the <c>shell</c> section of protocol/fixtures.json, the file the
/// Swift and Kotlin suites read too (ShellProtocolTests.swift and ShellProtocolTests.kt).
/// </summary>
public class ShellFixtureTests
{
    private static readonly JsonElement S = Fixtures.Root.GetProperty("shell");

    private static IEnumerable<string> Lines() =>
        S.GetProperty("messages").EnumerateArray().Select(m => m.GetProperty("line").GetString()!);

    private static ShellEnvelope Decode(string line) => ShellEnvelope.Decode(Encoding.UTF8.GetBytes(line));

    [Fact]
    public void Constants_MatchFixtures()
    {
        Assert.Equal(RemoteShell.DefaultPort, S.GetProperty("port").GetInt32());
        Assert.Equal(RemoteShell.ServiceType, S.GetProperty("serviceType").GetString());
        Assert.Equal(RemoteShell.ProofLabel, S.GetProperty("proofLabel").GetString());
        Assert.Equal(RemoteShell.MaxSessions, S.GetProperty("maxSessions").GetInt32());
        Assert.Equal(RemoteShell.ScrollbackBytes, S.GetProperty("scrollbackBytes").GetInt32());
        Assert.Equal(RemoteShell.OutputChunk, S.GetProperty("outputChunk").GetInt32());
        Assert.Equal(RemoteShell.LineLimit, S.GetProperty("lineLimit").GetInt32());
    }

    [Fact]
    public void Proof_MatchesFixture()
    {
        foreach (var p in S.GetProperty("proofs").EnumerateArray())
        {
            var key = Convert.FromBase64String(p.GetProperty("shellKey").GetString()!);
            var nonce = Convert.FromBase64String(p.GetProperty("nonce").GetString()!);
            var mac = Convert.FromBase64String(p.GetProperty("mac").GetString()!);
            Assert.Equal(mac, RemoteShell.Proof(key, nonce));
            Assert.True(RemoteShell.ProofIsValid(mac, key, nonce));
            var flipped = (byte[])mac.Clone();
            flipped[0] ^= 1;
            Assert.False(RemoteShell.ProofIsValid(flipped, key, nonce));
            Assert.False(RemoteShell.ProofIsValid(mac.AsSpan(0, 31), key, nonce));
        }
    }

    /// <summary>Every field survives a decode and re-encode, and nothing extra (like nulls) is added.</summary>
    [Fact]
    public void ShellMessages_RoundTrip()
    {
        var lines = Lines().ToList();
        Assert.True(lines.Count >= 44, $"only {lines.Count} lines");
        foreach (var line in lines)
        {
            var encoded = Encoding.UTF8.GetString(Decode(line).EncodeLine());
            Assert.EndsWith("\n", encoded);
            Assert.True(Fixtures.JsonEqual(encoded.TrimEnd('\n'), line), line);
        }
    }

    [Fact]
    public void ErrorReasons_MatchFixtures()
    {
        var wire = S.GetProperty("errors").EnumerateArray().Select(e => e.GetString()!).ToList();
        Assert.Equal(wire.OrderBy(w => w, StringComparer.Ordinal), ShellErrorWire.All.OrderBy(w => w, StringComparer.Ordinal));
        foreach (var w in wire) Assert.Equal(w, ShellErrorWire.Parse(w).ToWire());
        foreach (var e in Enum.GetValues<ShellError>()) Assert.Contains(e.ToWire(), wire);
        Assert.Equal(ShellError.BadRequest, ShellErrorWire.Parse("something_new"));
        Assert.Equal(ShellError.BadRequest, ShellErrorWire.Parse(null));
    }

    [Fact]
    public void HelloAndMacInfo_Fields()
    {
        Assert.Equal(ShellEnvelope.Hello, Decode(Lines().First(l => l.Contains("\"hello\""))).T);
        var info = Decode(Lines().First(l => l.Contains("\"macInfo\"")));
        Assert.Equal(ShellEnvelope.MacInfo, info.T);
        Assert.True(IrohInfo.IsValidId(info.IrohID));
        Assert.Equal("https://relay.example.com/", info.IrohRelay);
        Assert.Equal("relay-token-123", info.RelayToken);
        Assert.Equal(["192.168.1.20", "100.101.102.103"], info.Addresses!);
    }

    [Fact]
    public void HostStateAndControl_Fields()
    {
        var all = Lines().Select(Decode).ToList();
        var states = all.Where(m => m.T == ShellEnvelope.MacState).Select(m => m.State!).ToList();
        Assert.Equal(new HostState
        {
            Awake = true, Battery = 0.64, Charging = false, MinutesLeft = 190, BatteryFloor = 0.2, Hot = false,
            Vpn = HostState.VpnOn, VpnName = "NordVPN Germany", KillSwitch = true, Control = true, Internet = true,
        }, states[0]);
        Assert.Equal(new HostState { Awake = false, AwakeStopped = "battery", Battery = 0.19, Charging = false, BatteryFloor = 0.2, Control = false }, states[^1]);
        Assert.False(all.First(m => m.T == ShellEnvelope.SetAwake).On);
        Assert.True(all.First(m => m.T == ShellEnvelope.SetVpn).On);
        Assert.True(all.First(m => m.T == ShellEnvelope.Viewing).On);
        Assert.Contains(all, m => m.T == ShellEnvelope.Error && m.Reason == ShellError.NotAllowed.ToWire());
        Assert.Equal("{\"t\":\"lock\"}\n", Encoding.UTF8.GetString(new ShellEnvelope(ShellEnvelope.Lock).EncodeLine()));
    }

    [Fact]
    public void EventList_Fields()
    {
        var all = Lines().Select(Decode).ToList();
        Assert.Equal(1_758_060_000, all.First(m => m.T == ShellEnvelope.Events).Since);
        var list = all.First(m => m.T == ShellEnvelope.EventList);
        Assert.Equal(["vpn", "shell", "vpn"], list.EventEntries!.Select(e => e.Kind));
        Assert.True(list.EventEntries![^1].Warning);
        Assert.Null(list.EventEntries![0].Warning);
        Assert.Equal("3F2B8C1A-7D4E-4A55-9C0B-1E6F2A9D8B34", list.EventEntries![1].Session);
        Assert.Equal([new BatterySample { T = 1_758_059_900, Level = 0.64 }, new BatterySample { T = 1_758_060_300, Level = 0.62, Charging = true }], list.Battery!);
    }

    [Fact]
    public void SessionsAndHistory_Fields()
    {
        var all = Lines().Select(Decode).ToList();
        var waiting = all.Where(m => m.T == ShellEnvelope.Sessions).SelectMany(m => m.SessionList!).First(s => s.Waiting is not null);
        Assert.Equal("claude", waiting.Title);
        Assert.True(waiting.Running);
        var entry = all.Where(m => m.T == ShellEnvelope.HistoryList).SelectMany(m => m.HistoryEntries!).First(h => h.Cols is not null);
        Assert.Equal((48, 20), (entry.Cols, entry.Rows));
        Assert.Equal(48213, entry.Bytes);
        Assert.Contains(all, m => m.T == ShellEnvelope.TranscriptData && m.Cols is null && m.Rows is null);
        Assert.Equal("3F2B8C1A-7D4E-4A55-9C0B-1E6F2A9D8B34", all.First(m => m.T == ShellEnvelope.Replaying).Session);
    }

    [Fact]
    public void Decode_IgnoresUnknownFields_AndRefusesWrongTypes()
    {
        Assert.Equal("ping", ShellEnvelope.Decode("{\"t\":\"ping\",\"future\":{\"a\":1}}"u8).T);
        // A known key of the wrong JSON type fails the whole line, as on the phones: new
        // structured fields must never reuse an existing name.
        Assert.Throws<ProtocolException>(() => ShellEnvelope.Decode("{\"t\":\"sessions\",\"sessions\":\"x\"}"u8));
    }

    [Fact]
    public void Decode_NonJson_Throws()
    {
        Assert.Throws<ProtocolException>(() => ShellEnvelope.Decode("nope"u8));
        Assert.Throws<ProtocolException>(() => ShellEnvelope.Decode("{\"x\":1}"u8));
    }

    [Fact]
    public void Secrets_StayOutOfToString()
    {
        var envelope = new ShellEnvelope(ShellEnvelope.Proof) { Mac = "c2VjcmV0", Key = "a2V5", RelayToken = "tok" };
        Assert.Equal("ShellEnvelope(proof)", envelope.ToString());
        var pass = new ShellCredentialWire { MacID = "m", ShellKey = "c2VjcmV0", RelayToken = "tok" };
        Assert.DoesNotContain("c2VjcmV0", pass.ToString());
        Assert.DoesNotContain("tok", pass.ToString().Replace("relayToken", ""));
        var push = new PushRegistration { Token = "abcdef", Key = "a2V5", Mac = "m" };
        Assert.DoesNotContain("abcdef", push.ToString());
        Assert.DoesNotContain("a2V5", push.ToString());
    }

    [Fact]
    public void IrohValidation()
    {
        var id = string.Concat(Enumerable.Repeat("ab", 32));
        Assert.True(IrohInfo.IsValidId(id));
        Assert.False(IrohInfo.IsValidId(id[..^1]));
        Assert.False(IrohInfo.IsValidId(id.ToUpperInvariant()));
        Assert.False(IrohInfo.IsValidId("g" + id[1..]));
        Assert.True(IrohInfo.IsValidRelay("https://relay.example.com/"));
        Assert.False(IrohInfo.IsValidRelay("http://relay.example.com/"));
        Assert.False(IrohInfo.IsValidRelay("https://"));
        Assert.False(IrohInfo.IsValidRelay("https:\\relay.example.com\\"));
        Assert.False(IrohInfo.IsValidRelay("https://a.example.com/" + new string('x', 256)));
        Assert.True(IrohInfo.IsValidToken(new string('t', 512)));
        Assert.False(IrohInfo.IsValidToken(new string('t', 513)));
        Assert.True(IrohInfo.IsValidToken(new string('é', 256)));
        Assert.False(IrohInfo.IsValidToken(new string('é', 257)));
        Assert.False(IrohInfo.AreValid(null, "https://r.example.com/", "t"));
        Assert.True(IrohInfo.AreValid(id, null, null));
    }
}
