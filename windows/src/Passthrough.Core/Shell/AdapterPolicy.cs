namespace Passthrough.Core.Shell;

/// <summary>One network adapter as Windows describes it (GetAdaptersAddresses and GetIfEntry2), reduced to what the policy needs.</summary>
public sealed record AdapterFacts(string Id, string Name, int IfType, bool Up, bool HardwareInterface, bool ConnectorPresent, IReadOnlyList<AdapterAddress> Addresses);

public sealed record AdapterAddress(string Address, int PrefixLength, bool Preferred);

/// <summary>
/// What the Windows host makes of its adapters (stage 4 plan, section 7), with no Windows call: which are tunnels (for
/// the overlay ranges), which IPv6 prefixes are on-link, and which addresses a grant advertises.
/// </summary>
public static class AdapterPolicy
{
    public const int IfTypeEthernet = 6, IfTypeLoopback = 24, IfTypePropVirtual = 53, IfTypeWifi = 71, IfTypeTunnel = 131, IfTypeWwanPp = 243, IfTypeWwanPp2 = 244;

    /// <summary>
    /// A tunnel interface: what Wintun and WireGuard adapters report (Tailscale, NetBird, Headscale clients), virtual or
    /// tunnel type, no hardware and no connector. Never Ethernet (which Hyper-V and WSL switches and TAP adapters also
    /// report), Wi-Fi, WWAN or loopback: the Mac's "point-to-point utun" test has no meaning here.
    /// </summary>
    public static bool IsTunnel(AdapterFacts adapter) =>
        adapter.IfType is IfTypePropVirtual or IfTypeTunnel && !adapter.HardwareInterface && !adapter.ConnectorPresent;

    /// <summary>Every address, with whether its adapter is a tunnel: the address policy's view.</summary>
    public static IReadOnlyList<ShellAddressPolicy.LocalAddress> LocalAddresses(IEnumerable<AdapterFacts> adapters) =>
        [.. adapters.Where(a => a.Up).SelectMany(a => a.Addresses.Select(x => new ShellAddressPolicy.LocalAddress(x.Address, a.Name, IsTunnel(a))))];

    /// <summary>Global IPv6 prefixes of /64 or shorter on adapters that are up and neither tunnels nor loopback (LocalAddresses.swift).</summary>
    public static IReadOnlySet<string> OnLinkPrefixes(IEnumerable<AdapterFacts> adapters) =>
        ShellAddressPolicy.OnLinkPrefixes(adapters.Where(a => a.Up && !IsTunnel(a) && a.IfType != IfTypeLoopback)
            .SelectMany(a => a.Addresses.Where(x => x.Address.Contains(':') && x.PrefixLength is > 0 and <= 64).Select(x => x.Address)));

    /// <summary>
    /// What a grant and <c>macInfo</c> tell phones to dial: the policy's advertisable addresses among the preferred ones
    /// on adapters that are up and are hardware or tunnels, at most 16. Hyper-V and WSL switches' private addresses
    /// are left out: no phone can reach them.
    /// </summary>
    public static IReadOnlyList<string> Advertised(IEnumerable<AdapterFacts> adapters) =>
        [.. ShellAddressPolicy.Advertisable(adapters.Where(a => a.Up && (a.HardwareInterface || IsTunnel(a)))
            .SelectMany(a => a.Addresses.Where(x => x.Preferred).Select(x => x.Address))).Take(IrohInfo.MaxAddresses)];
}
