using System.Net;
using System.Net.Sockets;

namespace Passthrough.Core.Shell;

/// <summary>
/// Which peers may reach the shell, and which of this host's addresses a phone is told about: private networks,
/// loopback, link-local and Tailscale only (plus, for peers, global IPv6 addresses on the host's own links). A port of
/// <c>ShellAddressPolicy</c> in ShellProtocol.swift (protocol/README.md, "Address policy").
/// </summary>
public static class ShellAddressPolicy
{
    private enum Kind { None, Loopback, LinkLocal, Tailscale, Other }

    /// <summary>One of this host's own addresses, with whether it sits on an overlay network's tunnel.</summary>
    /// <param name="Address">The address, as text (a <c>%zone</c> suffix is allowed).</param>
    /// <param name="Interface">The interface it is on, for logs.</param>
    /// <param name="IsTunnel">
    /// The interface is a tunnel with no neighbours (macOS: a point-to-point <c>utun</c>; Windows: a non-hardware
    /// adapter of tunnel or virtual type, never Wi-Fi, Ethernet, WWAN or a Hyper-V or WSL switch). Decided by the caller.
    /// </param>
    public sealed record LocalAddress(string Address, string Interface, bool IsTunnel)
    {
        /// <summary>
        /// An overlay-range address on a tunnel, as Tailscale's, NetBird's and Headscale's clients set up. The same range
        /// on a physical interface is carrier-grade NAT handed out by the network.
        /// </summary>
        public bool IsOverlayTunnel => IsTunnel && IsOverlay(Address);
    }

    public static bool IsAllowed(string host) => Classify(host) != Kind.None;

    /// <summary>
    /// <see cref="IsAllowed(string)"/>, or a global IPv6 peer inside <paramref name="onLinkPrefixes"/>: the /64s this
    /// host has a global address in itself, so a neighbour on an IPv6-only LAN gets in and the rest of the internet does not.
    /// </summary>
    public static bool IsAllowed(string host, IReadOnlySet<string> onLinkPrefixes)
    {
        if (IsAllowed(host)) return true;
        return onLinkPrefixes.Count > 0 && GlobalPrefix(host) is { } prefix && onLinkPrefixes.Contains(prefix);
    }

    /// <summary>In an overlay network's range: 100.64.0.0/10 or Tailscale's fd7a:115c:a1e0::/48.</summary>
    public static bool IsOverlay(string host) => Classify(host) == Kind.Tailscale;

    /// <summary>
    /// <see cref="IsAllowed(string, IReadOnlySet{string})"/> for a peer reaching this host, except that an overlay-range
    /// peer is let in only while the host has an overlay address of that family on a tunnel. 100.64.0.0/10 is also
    /// carrier-grade NAT space: without an overlay tunnel here, a peer from it is the carrier's network.
    /// </summary>
    public static bool IsAllowedPeer(string host, Func<IReadOnlyList<LocalAddress>> localAddresses, Func<IReadOnlySet<string>> onLinkPrefixes)
    {
        if (IsOverlay(host))
        {
            var v4 = ParseV4(Bare(host)) is not null;
            return localAddresses().Any(a => a.IsOverlayTunnel && (ParseV4(Bare(a.Address)) is not null) == v4);
        }
        return IsAllowed(host) || IsAllowed(host, onLinkPrefixes());
    }

    /// <summary>
    /// Whether a connection from <paramref name="peer"/> that arrived on this host's address <paramref name="local"/> may
    /// go on: an overlay peer must have come in on one of this host's overlay tunnel addresses, not on a LAN (or
    /// carrier-grade NAT) address where anyone on that network could claim a 100.64.0.0/10 source. An overlay peer
    /// whose arrival address is unknown is refused; any other peer is up to <see cref="IsAllowedPeer"/> alone.
    /// </summary>
    public static bool ArrivedOnItsNetwork(string peer, string? local, Func<IReadOnlyList<LocalAddress>> localAddresses)
    {
        if (!IsOverlay(peer)) return true;
        if (local is null) return false;
        var arrival = Bare(local);
        return localAddresses().Any(a => a.IsOverlayTunnel && Bare(a.Address) == arrival);
    }

    /// <summary>The /64 prefixes (as hex) of the global unicast IPv6 addresses (2000::/3) among <paramref name="addresses"/>.</summary>
    public static IReadOnlySet<string> OnLinkPrefixes(IEnumerable<string> addresses) =>
        addresses.Select(GlobalPrefix).OfType<string>().ToHashSet(StringComparer.Ordinal);

    /// <summary>Allowed addresses worth dialing, deduplicated, with Tailscale last.</summary>
    public static IReadOnlyList<string> Advertisable(IEnumerable<string> addresses)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var kept = addresses.Where(a => Classify(a) is Kind.Other or Kind.Tailscale && seen.Add(a)).ToList();
        return [.. kept.Where(a => Classify(a) == Kind.Other), .. kept.Where(a => Classify(a) == Kind.Tailscale)];
    }

    /// <summary>The first 8 bytes (hex) of a global unicast IPv6 address; null for anything else.</summary>
    private static string? GlobalPrefix(string host)
    {
        if (ParseV6(Bare(host)) is not { } b || (b[0] & 0xE0) != 0x20) return null;
        return Convert.ToHexString(b, 0, 8);
    }

    internal static string Bare(string host)
    {
        var i = host.IndexOf('%');
        return i < 0 ? host : host[..i];
    }

    private static Kind Classify(string host)
    {
        var bare = Bare(host);
        if (ParseV4(bare) is { } v4)
        {
            return (v4[0], v4[1]) switch
            {
                (127, _) => Kind.Loopback,
                (169, 254) => Kind.LinkLocal,
                (100, >= 64 and <= 127) => Kind.Tailscale,
                (10, _) or (192, 168) => Kind.Other,
                (172, >= 16 and <= 31) => Kind.Other,
                _ => Kind.None,
            };
        }
        if (ParseV6(bare) is { } b)
        {
            if (b.Take(15).All(x => x == 0) && b[15] == 1) return Kind.Loopback;
            if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return Kind.LinkLocal;
            if (b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0) return Kind.Tailscale;
            if ((b[0] & 0xFE) == 0xFC) return Kind.Other;
        }
        return Kind.None;
    }

    /// <summary>A dotted quad of four decimal parts, 0 to 255 each, as inet_pton reads one; .NET's looser forms ("127.1", "0x7f.0.0.1") are not addresses here.</summary>
    internal static byte[]? ParseV4(string text)
    {
        var parts = text.Split('.');
        if (parts.Length != 4) return null;
        var bytes = new byte[4];
        for (int i = 0; i < 4; i++)
        {
            var p = parts[i];
            if (p.Length is < 1 or > 3 || !p.All(char.IsAsciiDigit) || (p.Length > 1 && p[0] == '0')) return null;
            var v = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
            if (v > 255) return null;
            bytes[i] = (byte)v;
        }
        return bytes;
    }

    internal static byte[]? ParseV6(string text) =>
        text.Contains(':') && IPAddress.TryParse(text, out var a) && a.AddressFamily == AddressFamily.InterNetworkV6 ? a.GetAddressBytes() : null;
}
