using Passthrough.Core.Shell;
using Xunit;
using static Passthrough.Core.Shell.ShellAddressPolicy;

namespace Passthrough.Core.Tests.Shell;

/// <summary>A port of the address policy tests in ShellProtocolTests.swift, plus the fixtures' cases.</summary>
public class ShellAddressPolicyTests
{
    private static readonly IReadOnlySet<string> NoPrefixes = new HashSet<string>();

    private static LocalAddress Lan(string address, string iface = "Ethernet") => new(address, iface, false);
    private static LocalAddress Tunnel(string address, string iface = "Tailscale") => new(address, iface, true);

    private static bool Peer(string host, IReadOnlyList<LocalAddress> local, IReadOnlySet<string>? prefixes = null) =>
        IsAllowedPeer(host, () => local, () => prefixes ?? NoPrefixes);

    [Fact]
    public void Fixtures()
    {
        foreach (var a in Passthrough.Core.Tests.Fixtures.Root.GetProperty("shell").GetProperty("addresses").EnumerateArray())
        {
            var host = a.GetProperty("host").GetString()!;
            Assert.True(a.GetProperty("allowed").GetBoolean() == IsAllowed(host), host);
        }
    }

    [Fact]
    public void AdvertisableOrdersTailscaleLast()
    {
        Assert.Equal(["192.168.1.5", "100.101.1.2"], Advertisable(["100.101.1.2", "192.168.1.5", "127.0.0.1", "fe80::1%en0", "192.168.1.5"]));
    }

    [Fact]
    public void OverlayPeersNeedThisHostOnAnOverlay()
    {
        var lan = new[] { Lan("192.168.1.5"), Lan("fe80::1%12") };
        Assert.False(Peer("100.101.1.2", lan));
        Assert.False(Peer("fd7a:115c:a1e0::5", lan));
        Assert.True(Peer("192.168.1.9", lan));
        Assert.True(Peer("fd00::9", lan)); // other ULAs are unchanged
        Assert.False(Peer("8.8.8.8", lan));
        var tailnet = lan.Append(Tunnel("100.90.0.1")).ToArray();
        Assert.True(Peer("100.101.1.2", tailnet));
        Assert.False(Peer("fd7a:115c:a1e0::5", tailnet)); // an IPv4 overlay address does not admit IPv6 overlay peers
        Assert.True(Peer("fd7a:115c:a1e0::5", [.. lan, Tunnel("fd7a:115c:a1e0::1")]));
        var prefixes = OnLinkPrefixes(["2001:db8:1:2::10"]);
        Assert.True(Peer("2001:db8:1:2::99", lan, prefixes));
        Assert.True(ArrivedOnItsNetwork("100.101.1.2", "100.90.0.1", () => tailnet));
        Assert.False(ArrivedOnItsNetwork("100.101.1.2", "192.168.1.5", () => tailnet));
        Assert.False(ArrivedOnItsNetwork("100.101.1.2", null, () => tailnet));
        Assert.True(ArrivedOnItsNetwork("192.168.1.9", "192.168.1.5", () => lan));
        Assert.True(ArrivedOnItsNetwork("192.168.1.9", null, () => lan));
    }

    [Fact]
    public void CarrierNatAddressesAreNotAnOverlay()
    {
        var cgnat = new[] { Lan("100.72.3.4"), Lan("192.168.1.5") };
        Assert.False(Peer("100.72.9.9", cgnat));
        Assert.False(Peer("100.72.9.9", [Tunnel("10.8.0.2")]));
        var both = cgnat.Append(Tunnel("100.90.0.1")).ToArray();
        Assert.True(Peer("100.101.1.2", both));
        Assert.True(ArrivedOnItsNetwork("100.101.1.2", "100.90.0.1", () => both));
        Assert.False(ArrivedOnItsNetwork("100.72.9.9", "100.72.3.4", () => both)); // arrived on the carrier's address
        Assert.True(ArrivedOnItsNetwork("fd7a:115c:a1e0::5", "fd7a:115c:a1e0::1%7", () => [Tunnel("fd7a:115c:a1e0::1")]));
    }

    [Fact]
    public void GlobalIPv6PeerOnlyFromThisHostsOwnPrefix()
    {
        var prefixes = OnLinkPrefixes(["2001:db8:1:2::10", "fe80::1%12", "192.168.1.5", "fd00::5"]);
        Assert.Single(prefixes); // only global addresses give prefixes
        Assert.True(IsAllowed("2001:db8:1:2:aaaa:bbbb:cccc:dddd", prefixes));
        Assert.True(IsAllowed("2001:db8:1:2::99%12", prefixes));
        Assert.False(IsAllowed("2001:db8:1:3::10", prefixes));
        Assert.False(IsAllowed("2a00:1450::1", prefixes));
        Assert.False(IsAllowed("2001:db8:1:2::10", NoPrefixes));
        Assert.False(IsAllowed("8.8.8.8", prefixes));
        Assert.True(IsAllowed("192.168.1.9", prefixes));
        Assert.False(IsAllowed("2001:db8:1:2::10")); // the plain policy is unchanged
        Assert.Empty(Advertisable(["2001:db8:1:2::10"])); // global addresses are never advertised
    }

    [Theory]
    [InlineData("127.1")]
    [InlineData("0x7f.0.0.1")]
    [InlineData("10.0.0")]
    [InlineData("010.0.0.1")]
    [InlineData("10.0.0.256")]
    [InlineData("")]
    public void LooseIPv4Forms_AreNotAddresses(string host)
    {
        Assert.False(IsAllowed(host)); // .NET would read some of these as private addresses
    }
}
