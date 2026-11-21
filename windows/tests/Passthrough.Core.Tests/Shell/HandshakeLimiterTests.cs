using Passthrough.Core.Shell;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>A port of HandshakeLimiterTests.swift, case for case (the file store comes with the listener).</summary>
public class HandshakeLimiterTests
{
    private static readonly TimeSpan Minute = TimeSpan.FromSeconds(60);

    private static HandshakeLimiter Limiter(int maxTotal = 16, int maxPerHost = 2, int reserved = 0, IProvenAddressStore? store = null,
        FakeTimeProvider? time = null, TimeSpan? timeout = null) =>
        new(timeout ?? Minute, time ?? new FakeTimeProvider(), store, maxTotal, maxPerHost, reserved);

    [Fact]
    public void LimitsPerHostAndInAll()
    {
        var limiter = Limiter(maxTotal: 3);
        var a1 = limiter.Acquire("a", () => { });
        var a2 = limiter.Acquire("a", () => { });
        Assert.NotNull(a1); Assert.NotNull(a2);
        Assert.Null(limiter.Acquire("a", () => { })); // a third from one address
        Assert.NotNull(limiter.Acquire("b", () => { }));
        Assert.Null(limiter.Acquire("c", () => { })); // every slot is taken
        Assert.True(a1!.Release());
        Assert.False(a1.Release()); // a slot is freed once
        Assert.Equal(2, limiter.Count);
        Assert.NotNull(limiter.Acquire("a", () => { }));
    }

    [Fact]
    public void IPv6PeersShareTheirSlash64()
    {
        var limiter = Limiter();
        var a = limiter.Acquire("2001:db8:1:2::1", () => { });
        Assert.NotNull(a);
        Assert.NotNull(limiter.Acquire("2001:db8:1:2:aaaa:bbbb:cccc:dddd", () => { }));
        Assert.Null(limiter.Acquire("2001:db8:1:2::99%12", () => { }));
        Assert.NotNull(limiter.Acquire("2001:db8:1:3::1", () => { }));
        Assert.True(a!.Release());
        Assert.NotNull(limiter.Acquire("2001:db8:1:2::7", () => { }));
        Assert.NotNull(limiter.Acquire("192.168.1.5", () => { }));
        Assert.NotNull(limiter.Acquire("192.168.1.6", () => { }));
    }

    [Fact]
    public void UlaNeighboursShareTheirSlash64()
    {
        var limiter = Limiter();
        Assert.NotNull(limiter.Acquire("fd00:1:2:3::1%12", () => { }));
        Assert.NotNull(limiter.Acquire("fd00:1:2:3::2", () => { }));
        Assert.Null(limiter.Acquire("fd00:1:2:3::3", () => { }));
    }

    [Fact]
    public void LinkLocalPeersAreCountedByAddress()
    {
        var limiter = Limiter();
        Assert.NotNull(limiter.Acquire("fe80::1%5", () => { }));
        Assert.NotNull(limiter.Acquire("fe80::1%5", () => { }));
        Assert.Null(limiter.Acquire("fe80::1%9", () => { })); // one address, whatever the link
        Assert.NotNull(limiter.Acquire("fe80::2%5", () => { }));
        Assert.NotNull(limiter.Acquire("febf::9", () => { })); // all of fe80::/10
        Assert.Equal(HandshakeLimiter.Bucket("fe80::1%5"), HandshakeLimiter.Bucket("fe80::1"));
        Assert.NotEqual(HandshakeLimiter.Bucket("fe80::1"), HandshakeLimiter.Bucket("fe80::2"));
        Assert.Equal(HandshakeLimiter.Bucket("2001:db8::1"), HandshakeLimiter.Bucket("2001:db8::2"));
    }

    [Fact]
    public void ProvenAddressesSurviveARelaunch()
    {
        var store = new MemoryProvenAddressStore();
        var time = new FakeTimeProvider();
        var first = Limiter(maxTotal: 2, reserved: 1, store: store, time: time);
        first.Proven("192.168.1.5");
        first.Proven("fe80::77%5");
        first.Proven("relay");
        Assert.Equal(new HashSet<string> { "192.168.1.5", "fe80::77" }, store.Load().Keys.ToHashSet());
        var relaunched = Limiter(maxTotal: 2, reserved: 1, store: store, time: time);
        Assert.True(relaunched.IsProven("192.168.1.5"));
        Assert.True(relaunched.IsProven("fe80::77"));
        Assert.NotNull(relaunched.Acquire("192.168.1.9", () => { }));
        Assert.Null(relaunched.Acquire("192.168.1.10", () => { })); // the shared slot is taken
        Assert.NotNull(relaunched.Acquire("192.168.1.5", () => { })); // the proven address still has the reserved one
    }

    [Fact]
    public void StoredProvenAddressesAreCheckedOnLoad()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(100_000_000);
        var table = new Dictionary<string, DateTimeOffset>
        {
            ["10.0.0.1"] = now - Minute,
            ["10.0.0.2"] = now - HandshakeLimiter.ProvenFor - TimeSpan.FromSeconds(1),
            ["relay"] = now,
            ["10.0.0.3"] = now + 10 * HandshakeLimiter.ProvenFor,
        };
        for (int i = 0; i < HandshakeLimiter.ProvenLimit + 10; i++)
            table[$"10.1.{i / 256}.{i % 256}"] = now - TimeSpan.FromSeconds(3600 + i);
        var kept = HandshakeLimiter.Kept(table, now);
        Assert.Equal(HandshakeLimiter.ProvenLimit, kept.Count);
        Assert.Equal(now - Minute, kept["10.0.0.1"]);
        Assert.False(kept.ContainsKey("10.0.0.2")); // expired
        Assert.False(kept.ContainsKey("relay"));
        Assert.Equal(now, kept["10.0.0.3"]); // from the future: as of now
        Assert.True(kept.ContainsKey("10.1.0.0"));
        Assert.False(kept.ContainsKey("10.1.1.9")); // the oldest went past the cap
    }

    private sealed class CountingStore : IProvenAddressStore
    {
        public int Saves;
        public IReadOnlyDictionary<string, DateTimeOffset> Table = new Dictionary<string, DateTimeOffset>();
        public IReadOnlyDictionary<string, DateTimeOffset> Load() => Table;
        public void Save(IReadOnlyDictionary<string, DateTimeOffset> proven) { Saves++; Table = proven; }
    }

    [Fact]
    public void ProvenAgainIsNotRewrittenEveryTime()
    {
        var store = new CountingStore();
        var time = new FakeTimeProvider();
        var limiter = new HandshakeLimiter(Minute, time, store);
        limiter.Proven("192.168.1.5");
        limiter.Proven("192.168.1.5");
        Assert.Equal(1, store.Saves);
        limiter.Proven("192.168.1.6");
        Assert.Equal(2, store.Saves);
        time.Advance(HandshakeLimiter.ResaveInterval);
        limiter.Proven("192.168.1.5");
        Assert.Equal(3, store.Saves);
        Assert.Equal(time.GetUtcNow(), store.Table["192.168.1.5"]);
    }

    [Fact]
    public void PublicIPv4PeersShareTheirSlash24()
    {
        var limiter = Limiter();
        Assert.NotNull(limiter.Acquire("203.0.113.5", () => { }));
        Assert.NotNull(limiter.Acquire("203.0.113.200", () => { }));
        Assert.Null(limiter.Acquire("203.0.113.9", () => { }));
        Assert.NotNull(limiter.Acquire("203.0.114.9", () => { }));
        foreach (var host in new[] { "10.0.0.1", "10.0.0.2", "172.16.0.1", "172.16.0.2", "100.100.1.1", "100.100.1.2", "169.254.1.1", "169.254.1.2" })
            Assert.NotNull(limiter.Acquire(host, () => { }));
    }

    [Fact]
    public void ProvenAddressesKeepReservedSlots()
    {
        var limiter = new HandshakeLimiter(Minute, new FakeTimeProvider());
        limiter.Proven("fe80::77%5");
        limiter.Proven("relay"); // not an address: never remembered
        var held = Enumerable.Range(0, 20).Select(i => limiter.Acquire($"192.168.1.{i + 10}", () => { })).OfType<HandshakeLimiter.Slot>().ToList();
        Assert.Equal(12, held.Count); // strangers get the shared slots only
        Assert.Null(limiter.Acquire("192.168.1.99", () => { }));
        Assert.Null(limiter.Acquire("relay", () => { }, maxForHost: 8));
        Assert.NotNull(limiter.Acquire("fe80::77%9", () => { })); // the proven address uses a reserved slot
        Assert.NotNull(limiter.Acquire("fe80::77", () => { }));
        Assert.Null(limiter.Acquire("fe80::77", () => { })); // still two at once from one address
        Assert.Equal(14, limiter.Count);
    }

    [Fact]
    public void ProvenAddressesAreForgottenAfterThirtyDays()
    {
        var time = new FakeTimeProvider();
        var limiter = Limiter(maxTotal: 2, reserved: 1, time: time);
        limiter.Proven("192.168.1.5");
        Assert.True(limiter.IsProven("192.168.1.5"));
        time.Advance(HandshakeLimiter.ProvenFor - TimeSpan.FromSeconds(1));
        Assert.True(limiter.IsProven("192.168.1.5"));
        time.Advance(TimeSpan.FromSeconds(2));
        Assert.False(limiter.IsProven("192.168.1.5"));
        Assert.NotNull(limiter.Acquire("192.168.1.5", () => { }));
        Assert.Null(limiter.Acquire("192.168.1.5", () => { })); // unproven again: the reserved slot is not for it
    }

    [Fact]
    public void TimeoutFreesTheSlotOnce()
    {
        var time = new FakeTimeProvider();
        var limiter = Limiter(maxTotal: 1, maxPerHost: 1, time: time, timeout: TimeSpan.FromSeconds(10));
        var timedOut = 0;
        Assert.NotNull(limiter.Acquire("a", () => timedOut++));
        Assert.Null(limiter.Acquire("b", () => { }));
        time.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal(1, timedOut);
        Assert.Equal(0, limiter.Count);
        var released = 0;
        var slot = limiter.Acquire("b", () => released++);
        Assert.True(slot!.Release()); // released before the timeout
        time.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal(0, released);
    }
}
