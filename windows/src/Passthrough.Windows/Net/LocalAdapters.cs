using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Passthrough.Core.Shell;

namespace Passthrough.Windows.Net;

/// <summary>
/// This PC's adapters as <see cref="AdapterFacts"/> (GetAdaptersAddresses through .NET, plus GetIfEntry2 for whether
/// an adapter is hardware and has a connector), cached for up to 2 s, so a flood of connections doesn't list adapters
/// for each one.
/// </summary>
public sealed class LocalAdapters
{
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(2);
    private readonly Lock _lock = new();
    private IReadOnlyList<AdapterFacts> _facts = [];
    private DateTime _readAt = DateTime.MinValue;

    public IReadOnlyList<AdapterFacts> Facts
    {
        get
        {
            lock (_lock)
            {
                if (DateTime.UtcNow - _readAt < MaxAge) return _facts;
                _facts = Read();
                _readAt = DateTime.UtcNow;
                return _facts;
            }
        }
    }

    /// <summary>Forgets the cache (an address changed, or the PC woke).</summary>
    public void Invalidate()
    {
        lock (_lock) _readAt = DateTime.MinValue;
    }

    public static IReadOnlyList<AdapterFacts> Read()
    {
        var facts = new List<AdapterFacts>();
        NetworkInterface[] adapters;
        try { adapters = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { return []; }
        foreach (var adapter in adapters)
        {
            IPInterfaceProperties properties;
            int index;
            try
            {
                properties = adapter.GetIPProperties();
                index = adapter.Supports(NetworkInterfaceComponent.IPv4) ? properties.GetIPv4Properties().Index : properties.GetIPv6Properties().Index;
            }
            catch (Exception e) when (e is NetworkInformationException or PlatformNotSupportedException) { continue; }
            var (hardware, connector, ifType) = Row(index);
            var addresses = properties.UnicastAddresses
                .Where(a => a.Address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
                .Select(a => new AdapterAddress(a.Address.ToString(), a.PrefixLength, a.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Preferred))
                .ToList();
            facts.Add(new AdapterFacts(adapter.Id, adapter.Name, ifType ?? (int)adapter.NetworkInterfaceType, adapter.OperationalStatus == OperationalStatus.Up, hardware, connector, addresses));
        }
        return facts;
    }

    /// <summary>MIB_IF_ROW2's type and its InterfaceAndOperStatusFlags (bit 0 hardware, bit 2 connector present).</summary>
    private static (bool Hardware, bool Connector, int? IfType) Row(int index)
    {
        var row = new byte[RowSize];
        BitConverter.TryWriteBytes(row.AsSpan(8), index);
        if (GetIfEntry2(row) != 0) return (false, false, null);
        var flags = row[FlagsOffset];
        return ((flags & 0x1) != 0, (flags & 0x4) != 0, BitConverter.ToInt32(row, TypeOffset));
    }

    // MIB_IF_ROW2: InterfaceLuid (8), InterfaceIndex (4), InterfaceGuid (16), Alias and Description (257 WCHARs each),
    // PhysicalAddressLength (4), PhysicalAddress and PermanentPhysicalAddress (32 each), Mtu, Type, TunnelType,
    // MediaType, PhysicalMediumType, AccessType, DirectionType (4 each), then the flags byte.
    private const int RowSize = 1352, TypeOffset = 1128, FlagsOffset = 1152;

    [DllImport("iphlpapi.dll")]
    private static extern int GetIfEntry2([In, Out] byte[] row);
}

/// <summary>This PC's one name for phones (stage 4 plan, section 7): the DNS-SD instance name and the grant's <c>macName</c>.</summary>
public static class HostName
{
    /// <summary>The physical DNS host name, cut to 63 UTF-8 bytes on a character boundary.</summary>
    public static string Current()
    {
        var size = 0u;
        GetComputerNameEx(5 /* ComputerNamePhysicalDnsHostname */, null, ref size);
        var buffer = new StringBuilder((int)size + 1);
        var name = GetComputerNameEx(5, buffer, ref size) && buffer.Length > 0 ? buffer.ToString() : Environment.MachineName;
        return Cut(name, 63);
    }

    internal static string Cut(string text, int maxBytes)
    {
        if (Encoding.UTF8.GetByteCount(text) <= maxBytes) return text;
        var end = text.Length;
        while (end > 0 && Encoding.UTF8.GetByteCount(text.AsSpan(0, end)) > maxBytes) end--;
        if (end > 0 && char.IsHighSurrogate(text[end - 1])) end--;
        return text[..end];
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetComputerNameExW", SetLastError = true)]
    private static extern bool GetComputerNameEx(int format, StringBuilder? buffer, ref uint size);
}
