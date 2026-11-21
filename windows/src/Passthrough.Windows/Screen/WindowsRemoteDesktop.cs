using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;
using Passthrough.Core.Screen;
using Passthrough.Core.Setup;
using Passthrough.Windows.Setup;

namespace Passthrough.Windows.Screen;

/// <summary>
/// The elevated step's hands on Remote Desktop: <c>fDenyTSConnections</c> and NLA in the registry (which touch no
/// firewall rule: Windows' own Remote Desktop rules are never edited), TermService's start type, and Remote Desktop
/// Users by SID (the group's name is translated).
/// </summary>
public sealed class WindowsRemoteDesktop : IRemoteDesktopSystem
{
    private const string TerminalServer = @"SYSTEM\CurrentControlSet\Control\Terminal Server";
    private const string RdpTcp = TerminalServer + @"\WinStations\RDP-Tcp";
    private static readonly SecurityIdentifier RemoteDesktopUsers = new(WellKnownSidType.BuiltinRemoteDesktopUsersSid, null);
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private readonly WindowsServiceControl _termService = new("TermService");

    private static RegistryKey Key(string path) =>
        RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(path, writable: true)
        ?? throw new SetupException("Remote Desktop's settings aren't on this PC.");

    public RemoteDesktopFacts Facts() => RemoteDesktopProbe.Read();

    public void SetAllowed(bool on)
    {
        using var key = Key(TerminalServer);
        key.SetValue("fDenyTSConnections", on ? 0 : 1, RegistryValueKind.DWord);
    }

    public void SetNla(bool required, int? prior = null)
    {
        using var key = Key(RdpTcp);
        if (required) key.SetValue("UserAuthentication", 1, RegistryValueKind.DWord);
        else if (prior is { } value) key.SetValue("UserAuthentication", value, RegistryValueKind.DWord);
        else key.DeleteValue("UserAuthentication", throwOnMissingValue: false);
    }

    public int StartType() => _termService.Query()?.StartType switch
    {
        ServiceStart.Automatic => 2,
        ServiceStart.Disabled => 4,
        _ => 3,
    };

    public void SetStartType(int start) => _termService.SetStartType(start switch { 2 => ServiceStart.Automatic, 4 => ServiceStart.Disabled, _ => ServiceStart.Manual });

    public void StartService()
    {
        if (!_termService.IsRunning()) _termService.Start(TimeSpan.FromSeconds(20));
    }

    public bool MayUseRemoteDesktop(string sid) => Members(Administrators).Contains(sid) || Members(RemoteDesktopUsers).Contains(sid);

    public void AddToRemoteDesktopUsers(string sid) => Change(sid, add: true);

    public void RemoveFromRemoteDesktopUsers(string sid) => Change(sid, add: false);

    private static string GroupName(SecurityIdentifier group) => ((NTAccount)group.Translate(typeof(NTAccount))).Value.Split('\\')[^1];

    /// <summary>Direct members of a local group, as SIDs.</summary>
    private static HashSet<string> Members(SecurityIdentifier group)
    {
        var members = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var resume = IntPtr.Zero;
        var result = NetLocalGroupGetMembers(null, GroupName(group), 0, out var buffer, -1, out var read, out _, ref resume);
        if (result != 0) throw new Win32Exception(result, "NetLocalGroupGetMembers");
        try
        {
            for (var i = 0; i < read; i++) members.Add(new SecurityIdentifier(Marshal.ReadIntPtr(buffer, i * IntPtr.Size)).Value);
        }
        finally { NetApiBufferFree(buffer); }
        return members;
    }

    private static void Change(string sid, bool add)
    {
        var identifier = new SecurityIdentifier(sid);
        var bytes = new byte[identifier.BinaryLength];
        identifier.GetBinaryForm(bytes, 0);
        var pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var info = new[] { pinned.AddrOfPinnedObject() };
            var name = GroupName(RemoteDesktopUsers);
            var result = add ? NetLocalGroupAddMembers(null, name, 0, info, 1) : NetLocalGroupDelMembers(null, name, 0, info, 1);
            // 1378: already a member; 1377: not one.
            if (result != 0 && result != 1378 && result != 1377) throw new Win32Exception(result, add ? "NetLocalGroupAddMembers" : "NetLocalGroupDelMembers");
        }
        finally { pinned.Free(); }
    }

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetLocalGroupGetMembers(string? server, string group, int level, out IntPtr buffer, int max, out int read, out int total, ref IntPtr resume);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetLocalGroupAddMembers(string? server, string group, int level, IntPtr[] members, int count);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetLocalGroupDelMembers(string? server, string group, int level, IntPtr[] members, int count);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr buffer);
}
