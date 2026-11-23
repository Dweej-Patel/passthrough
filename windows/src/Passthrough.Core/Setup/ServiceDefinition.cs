namespace Passthrough.Core.Setup;

/// <summary>
/// Everything fixed about Passthrough's background service and what the install puts on the PC (stage 4 plan,
/// sections 2 and 3): names, the service's security, the folders' security, the firewall rules.
/// </summary>
public static class ServiceDefinition
{
    public const string Name = "PassthroughService";
    public const string DisplayName = "Passthrough Remote Access";
    public const string Description = "Lets phones you have allowed reach this PC. Turn it off in Passthrough's settings.";
    public const string ExeName = "Passthrough.Service.exe";
    public const string AppExeName = "Passthrough.exe";
    public const string ManifestName = "files.json";
    public const string StateFileName = "install.json";
    /// <summary>The service's own account: a virtual account, no password; its SID is <see cref="Sid"/>.</summary>
    public const string Account = @"NT SERVICE\" + Name;
    public const string RegistryKey = @"SOFTWARE\Passthrough";
    public const string FirewallGroup = "Passthrough";
    /// <summary>
    /// The rules that keep Remote Desktop closed to the network live in a group of their own, so an update or repair
    /// (which replaces the <see cref="FirewallGroup"/> rules) never takes them away while Remote Desktop stays on.
    /// </summary>
    public const string RemoteDesktopFirewallGroup = "Passthrough Remote Desktop";
    public const string BlockTcpRuleName = "Passthrough: keep Remote Desktop closed (TCP-In)";
    public const string BlockUdpRuleName = "Passthrough: keep Remote Desktop closed (UDP-In)";

    /// <summary>Inbound block rules for Remote Desktop's port, every profile, every address: a block wins over any allow rule.</summary>
    public static IReadOnlyList<FirewallRule> BlockRules(int port) =>
    [
        new FirewallRule(BlockTcpRuleName, Protocol: 6, LocalPorts: port.ToString(System.Globalization.CultureInfo.InvariantCulture), Program: "", Service: null,
            RemoteAddresses: "*", Group: RemoteDesktopFirewallGroup, Block: true),
        new FirewallRule(BlockUdpRuleName, Protocol: 17, LocalPorts: port.ToString(System.Globalization.CultureInfo.InvariantCulture), Program: "", Service: null,
            RemoteAddresses: "*", Group: RemoteDesktopFirewallGroup, Block: true),
    ];
    public const string ShortcutName = "Passthrough.lnk";
    /// <summary>At most this many Windows accounts may use the service (RECONCILIATION: up to 4).</summary>
    public const int MaxAccounts = 4;
    /// <summary>Earliest Windows build installed on (1809).</summary>
    public const int MinimumBuild = 17763;
    /// <summary>Windows' TLS serves 1.3 from this build: below it there is no listener on the network (section 7).</summary>
    public const int TlsListenerBuild = 20348;

    /// <summary>
    /// Re-read install.json and the store (after <c>--configure</c>). Only SYSTEM and administrators may send a
    /// user-defined control (RECONCILIATION, the stage 4 fix), and it only re-reads what administrators wrote. No
    /// control deletes anything: <c>--remove</c> deletes the service's profile, and its keys with it.
    /// </summary>
    public const int ControlReload = 201;
    /// <summary>
    /// The one copy of the service exe whose path never changes (<c>%ProgramFiles%\Passthrough\Passthrough.Service.exe</c>):
    /// the service runs it, and Start at login and the Start menu run it with <see cref="LaunchVerb"/>, which starts the
    /// installed app. Install folders come and go with builds; this doesn't, so no account's Run value ever dangles.
    /// </summary>
    public const string LaunchVerb = "--launch";

    /// <summary><c>NT SERVICE\PassthroughService</c>.</summary>
    public static string Sid { get; } = ServiceSid.For(Name);

    /// <summary>
    /// The service's own security. SYSTEM: query and control; administrators: everything; interactive users: query and
    /// interrogate only (no user-defined controls, so nobody else can send <see cref="ControlReload"/>); each
    /// allowed account may also start it (query status, start, interrogate), never stop or change it.
    /// </summary>
    public static string ServiceSddl(IEnumerable<string> allowedAccounts) =>
        "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLORC;;;IU)"
        + string.Concat(allowedAccounts.Select(a => $"(A;;RPLCLO;;;{a})"));

    /// <summary><c>%ProgramData%\Passthrough</c>: SYSTEM and administrators full; the service reads (owner Administrators, inheritance cut).</summary>
    public static string DataFolderSddl => $"O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;{Sid})";

    /// <summary><c>store\</c>: the service may change what is in it; nobody else but SYSTEM and administrators.</summary>
    public static string StoreFolderSddl => $"O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;{Sid})";

    /// <summary>
    /// <c>logs\</c>: as <c>store\</c>. Not readable by the allowed accounts: on a shared PC it names other accounts'
    /// phones; an account gets its own lines through the pipe.
    /// </summary>
    public static string LogsFolderSddl => StoreFolderSddl;

    /// <summary><c>%ProgramFiles%\Passthrough</c>: administrators and SYSTEM write; every user and the service read and run.</summary>
    public static string ProgramFolderSddl => $"O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;{Sid})";

    /// <summary>The service's exe, at the path that never changes.</summary>
    public static string ServiceExe(string programFolder) => WinPath.Join(programFolder, ExeName);

    /// <summary>The firewall rules for an install of the app in <paramref name="installFolder"/> on Windows build <paramref name="build"/>.</summary>
    public static IReadOnlyList<FirewallRule> FirewallRules(string programFolder, string installFolder, int build)
    {
        var service = ServiceExe(programFolder);
        var rules = new List<FirewallRule>();
        if (build >= TlsListenerBuild)
            rules.Add(new FirewallRule(TcpRuleName, Protocol: 6, LocalPorts: "7893", Program: service, Service: Name,
                RemoteAddresses: "LocalSubnet,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,fc00::/7,fe80::/10"));
        rules.Add(new FirewallRule(UdpRuleName, Protocol: 17, LocalPorts: "*", Program: service, Service: Name, RemoteAddresses: "*"));
        // The tray app's pairing listener (stage 7: two computers pair on the same network only).
        rules.Add(new FirewallRule(PairingRuleName, Protocol: 6, LocalPorts: "*", Program: WinPath.Join(installFolder, AppExeName), Service: null,
            RemoteAddresses: "LocalSubnet"));
        return rules;
    }

    public const string TcpRuleName = "Passthrough Remote Access (TCP-In)";
    public const string UdpRuleName = "Passthrough Remote Access (UDP-In)";
    public const string PairingRuleName = "Passthrough Pairing (TCP-In)";
    public static readonly IReadOnlyList<string> RuleNames = [TcpRuleName, UdpRuleName, PairingRuleName];
}

/// <summary>One inbound rule, in every profile, no edge traversal: allow (or <paramref name="Block"/>), in <paramref name="Group"/>.</summary>
public sealed record FirewallRule(string Name, int Protocol, string LocalPorts, string Program, string? Service, string RemoteAddresses, bool Enabled = true,
    string Group = ServiceDefinition.FirewallGroup, bool Block = false);
