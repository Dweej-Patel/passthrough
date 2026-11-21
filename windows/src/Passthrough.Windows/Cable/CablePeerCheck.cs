using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Passthrough.Core.Cable;
using Passthrough.Core.Transport;

namespace Passthrough.Windows.Cable;

/// <summary>
/// The cable peer check (stage 3 plan): before a control channel proves anything, who holds the far end of its
/// connection. A shell grant goes only to a genuine one, so a program standing in on usbmuxd's or adb's port can pair
/// at most, never become a shell. For an iPhone or iPad that is Apple's device service: the classic Apple Mobile Device
/// Service (its process, as the Service Control Manager says), or Apple Devices' own process, told by the package
/// identity Windows gives it, which a stand-in can't claim. For Android it is an adb server running as this user, in
/// this Windows session. Any failure to decide is <see cref="PeerVerdict.Unknown"/>: no grant.
/// </summary>
public static class CablePeerCheck
{
    internal const string AppleServiceName = "Apple Mobile Device Service";
    /// <summary>Apple Devices (the Microsoft Store app): its package family, publisher id included.</summary>
    internal const string AppleDevicesFamily = "AppleInc.AppleDevices_nzyj5cx40ttqa";

    public static PeerVerdict Check(Stream stream, PhoneKind kind)
    {
        try
        {
            if (stream is not IEndpointStream { LocalEndPoint: { } local, RemoteEndPoint: { } remote }) return PeerVerdict.Unknown;
            if (OwnerOf(remote, local) is not { } pid) return PeerVerdict.Unknown;
            return kind is PhoneKind.IPhone or PhoneKind.IPad
                ? IsAppleDeviceService(pid) ? PeerVerdict.Genuine : PeerVerdict.NotGenuine
                : IsThisUsersInThisSession(pid) ? PeerVerdict.Genuine : PeerVerdict.NotGenuine;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or UnauthorizedAccessException or ArgumentException)
        {
            return PeerVerdict.Unknown;
        }
    }

    /// <summary>The process owning the server side of our connection: the row whose local end is our remote end, and back.</summary>
    internal static int? OwnerOf(IPEndPoint server, IPEndPoint client)
    {
        // A dual-mode socket names IPv4 ends as IPv4-mapped IPv6; the table holds them as IPv4.
        server = V4(server);
        client = V4(client);
        if (server.AddressFamily != AddressFamily.InterNetwork || client.AddressFamily != AddressFamily.InterNetwork) return null;
        foreach (var row in TcpRows())
            if (row.Local.Equals(server) && row.Remote.Equals(client)) return row.Pid;
        return null;
    }

    private static IPEndPoint V4(IPEndPoint end) => end.Address.IsIPv4MappedToIPv6 ? new IPEndPoint(end.Address.MapToIPv4(), end.Port) : end;

    private static bool IsAppleDeviceService(int pid) => ServiceProcessId(AppleServiceName) == pid || PackageFamilyOf(pid) == AppleDevicesFamily;

    private static bool IsThisUsersInThisSession(int pid)
    {
        using var process = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, pid);
        if (process.IsInvalid) return false;
        if (!Native.ProcessIdToSessionId(pid, out var session) || !Native.ProcessIdToSessionId(Environment.ProcessId, out var ours) || session != ours) return false;
        if (!Native.OpenProcessToken(process, Native.TokenQuery, out var token)) return false;
        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        using (var me = WindowsIdentity.GetCurrent())
            return identity.User is { } user && me.User is { } mine && user.Equals(mine);
    }

    private static int? ServiceProcessId(string name)
    {
        var manager = Native.OpenSCManager(null, null, Native.ScManagerConnect);
        if (manager == IntPtr.Zero) return null;
        try
        {
            var service = Native.OpenService(manager, name, Native.ServiceQueryStatus);
            if (service == IntPtr.Zero) return null;
            try
            {
                var status = new Native.ServiceStatusProcess();
                return Native.QueryServiceStatusEx(service, 0, ref status, Marshal.SizeOf<Native.ServiceStatusProcess>(), out _) && status.ProcessId != 0
                    ? (int)status.ProcessId : null;
            }
            finally { Native.CloseServiceHandle(service); }
        }
        finally { Native.CloseServiceHandle(manager); }
    }

    private static string? PackageFamilyOf(int pid)
    {
        using var process = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, pid);
        if (process.IsInvalid) return null;
        var length = 0u;
        if (Native.GetPackageFamilyName(process, ref length, null) != Native.ErrorInsufficientBuffer || length == 0) return null; // not packaged
        var name = new char[length];
        return Native.GetPackageFamilyName(process, ref length, name) == 0 ? new string(name, 0, (int)length - 1) : null;
    }

    private readonly record struct TcpRow(IPEndPoint Local, IPEndPoint Remote, int Pid);

    private static List<TcpRow> TcpRows()
    {
        var size = 0;
        Native.GetExtendedTcpTable(IntPtr.Zero, ref size, false, Native.AfInet, Native.TcpTableOwnerPidConnections, 0);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                var result = Native.GetExtendedTcpTable(buffer, ref size, false, Native.AfInet, Native.TcpTableOwnerPidConnections, 0);
                if (result == Native.ErrorInsufficientBuffer) continue;
                if (result != 0) throw new System.ComponentModel.Win32Exception((int)result, "GetExtendedTcpTable");
                var count = Marshal.ReadInt32(buffer);
                var rows = new List<TcpRow>(count);
                var rowSize = Marshal.SizeOf<Native.TcpRowOwnerPid>();
                for (var i = 0; i < count; i++)
                {
                    var row = Marshal.PtrToStructure<Native.TcpRowOwnerPid>(buffer + 4 + i * rowSize);
                    rows.Add(new TcpRow(Endpoint(row.LocalAddr, row.LocalPort), Endpoint(row.RemoteAddr, row.RemotePort), (int)row.OwningPid));
                }
                return rows;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        return [];
    }

    /// <summary>The table's ports are in network order in the low two bytes.</summary>
    private static IPEndPoint Endpoint(uint address, uint port) =>
        new(new IPAddress(address), (int)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF)));

    private static class Native
    {
        public const int AfInet = 2;
        public const int TcpTableOwnerPidConnections = 4;
        public const uint ErrorInsufficientBuffer = 122;
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const uint TokenQuery = 0x0008;
        public const uint ScManagerConnect = 0x0001;
        public const uint ServiceQueryStatus = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        public struct TcpRowOwnerPid { public uint State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceStatusProcess
        {
            public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags;
        }

        [DllImport("iphlpapi.dll")]
        public static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ProcessIdToSessionId(int pid, out uint session);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern uint GetPackageFamilyName(SafeProcessHandle process, ref uint length, [Out] char[]? name);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "OpenSCManagerW")]
        public static extern IntPtr OpenSCManager(string? machine, string? database, uint access);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "OpenServiceW")]
        public static extern IntPtr OpenService(IntPtr manager, string name, uint access);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool QueryServiceStatusEx(IntPtr service, int infoLevel, ref ServiceStatusProcess status, int size, out int needed);

        [DllImport("advapi32.dll")]
        public static extern bool CloseServiceHandle(IntPtr handle);
    }
}
