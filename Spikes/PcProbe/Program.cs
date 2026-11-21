// Throwaway spike: what can this PC do for Remote access? Reads only, changes nothing,
// needs no administrator. See README.md for the question and the answer.

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;

namespace PcProbe;

internal static class Program
{
    private static int Main()
    {
        Section("Windows");
        using (var cv = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
        {
            Line("Product", cv?.GetValue("ProductName"));
            Line("EditionID", cv?.GetValue("EditionID"));
            Line("Build", $"{cv?.GetValue("CurrentBuildNumber")}.{cv?.GetValue("UBR")}");
        }
        Line("Version", Environment.OSVersion.Version);
        Line("TLS 1.3 server (Windows 11 / Server 2022: build 20348 or later)", Environment.OSVersion.Version.Build >= 20348);

        Section("Remote Desktop: may this edition host it");
        Try("Licence value AllowRemoteConnections", () =>
        {
            int hr = SLGetWindowsInformationDWORD("TerminalServices-RemoteConnectionManager-AllowRemoteConnections", out uint allowed);
            return hr == 0 ? allowed.ToString() : $"HRESULT 0x{hr:X8}";
        });
        Try("Licence value AllowMultipleSessions", () =>
        {
            int hr = SLGetWindowsInformationDWORD("TerminalServices-RemoteConnectionManager-AllowMultipleSessions", out uint allowed);
            return hr == 0 ? allowed.ToString() : $"HRESULT 0x{hr:X8}";
        });

        Section("Remote Desktop: how it is set");
        int port = 3389;
        using (var ts = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server"))
        {
            Line("fDenyTSConnections (0 = on)", ts?.GetValue("fDenyTSConnections"));
        }
        using (var tcp = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"))
        {
            if (tcp?.GetValue("PortNumber") is int p) port = p;
            Line("PortNumber", port);
            Line("UserAuthentication (1 = NLA required)", tcp?.GetValue("UserAuthentication"));
            Line("SecurityLayer (2 = TLS)", tcp?.GetValue("SecurityLayer"));
            Line("SSLCertificateSHA1Hash set (a configured certificate)", tcp?.GetValue("SSLCertificateSHA1Hash") is byte[]);
        }
        using (var pol = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"))
        {
            Line("Group Policy key present", pol is not null);
            if (pol is not null) Line("  policy values", string.Join(", ", pol.GetValueNames()));
        }

        Section("Remote Desktop service, as an unprivileged caller sees it");
        uint termPid = 0;
        Try("TermService", () =>
        {
            var s = QueryService("TermService");
            termPid = s.dwProcessId;
            return $"state {s.dwCurrentState} (4 = running), type 0x{s.dwServiceType:X} (0x20 = shares a process), pid {s.dwProcessId}";
        });

        Section("Remote Desktop: does it answer on loopback, and who is at the far end");
        Try("X.224 on 127.0.0.1", () => ProbeLoopback(port, termPid));

        Section("Remote Desktop certificate, readable without rights");
        Try("LocalMachine\\Remote Desktop store", () =>
        {
            using var store = new System.Security.Cryptography.X509Certificates.X509Store("Remote Desktop", System.Security.Cryptography.X509Certificates.StoreLocation.LocalMachine);
            store.Open(System.Security.Cryptography.X509Certificates.OpenFlags.ReadOnly);
            var parts = new List<string>();
            foreach (var c in store.Certificates)
            {
                string sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(c.RawData)).ToLowerInvariant();
                parts.Add($"sha256 {sha256[..16]}… expires {c.NotAfter:yyyy-MM-dd}, lifetime {(c.NotAfter - c.NotBefore).TotalDays:F0} days");
            }
            return parts.Count == 0 ? "empty" : string.Join("; ", parts);
        });

        Section("Windows Firewall");
        Try("Profiles and rules for the Remote Desktop port", () => Firewall(port));

        Section("This account");
        var identity = WindowsIdentity.GetCurrent();
        string user = identity.Name.Contains('\\') ? identity.Name[(identity.Name.IndexOf('\\') + 1)..] : identity.Name;
        Line("Elevated", new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator));
        Try("Kind", () => AccountKind(user));
        Try("Local groups", () => string.Join(", ", LocalGroups(user)));
        using (var pl = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"))
        {
            Line("\"Only allow Windows Hello sign-in\" (2 = on, 0 = off)", pl?.GetValue("DevicePasswordLessBuildVersion") ?? "not set");
        }
        Try("Entra / domain join", () =>
        {
            string text = Run("dsregcmd.exe", "/status");
            var keep = text.Split('\n').Select(l => l.Trim())
                .Where(l => l.StartsWith("AzureAdJoined") || l.StartsWith("DomainJoined") || l.StartsWith("EnterpriseJoined"));
            return string.Join("; ", keep);
        });

        Section("Sleep");
        Try("Sleep after (plugged in / on battery), seconds; 0 = never", () =>
        {
            Check(PowerGetActiveScheme(IntPtr.Zero, out IntPtr scheme));
            try
            {
                var sub = new Guid("238c9fa8-0aad-41ed-83f4-97be242c8f20");
                var idle = new Guid("29f6c1db-86da-48c5-9fdb-f2b67b1f44da");
                Check(PowerReadACValueIndex(IntPtr.Zero, scheme, ref sub, ref idle, out uint ac));
                Check(PowerReadDCValueIndex(IntPtr.Zero, scheme, ref sub, ref idle, out uint dc));
                return $"{ac} / {dc}";
            }
            finally { LocalFree(scheme); }
        });
        Try("Sleep states", () =>
        {
            string text = Run("powercfg.exe", "/a");
            return text.Contains("S0 Low Power Idle") && text.IndexOf("S0 Low Power Idle", StringComparison.Ordinal) < IndexOfOrMax(text, "not available")
                ? "Modern Standby (S0 Low Power Idle) available"
                : "No Modern Standby; " + string.Join(", ", text.Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("Standby (S")).Take(3));
        });
        Line("Battery present", SystemInformationBattery());

        Section("BitLocker (best effort without rights)");
        Try("OS volume", () =>
        {
            string text = Run("manage-bde.exe", "-status C:");
            return text.Contains("Protection On") ? "Protection On (key protectors need an administrator to list)"
                : text.Contains("Protection Off") ? "Protection Off" : "needs an administrator to read";
        });

        Section("Shells this PC has");
        foreach (var (name, path) in Shells()) Line(name, path);

        return 0;
    }

    // ---- Remote Desktop on loopback ---------------------------------------------------------

    private static string ProbeLoopback(int port, uint termPid)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        socket.Connect(new IPEndPoint(IPAddress.Loopback, port));
        var local = (IPEndPoint)socket.LocalEndPoint!;

        // X.224 Connection Request with an RDP negotiation request for TLS, CredSSP and CredSSP-EX.
        byte[] request =
        [
            0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x08, 0x00, 0x0B, 0x00, 0x00, 0x00,
        ];
        socket.Send(request);
        socket.ReceiveTimeout = 5000;
        byte[] reply = new byte[64];
        int n = socket.Receive(reply);

        string answer = n >= 19 && reply[11] == 0x02
            ? $"negotiation response, selected protocol {BitConverter.ToUInt32(reply, 15)} (1 TLS, 2 CredSSP/NLA, 8 CredSSP-EX)"
            : n >= 19 && reply[11] == 0x03
                ? $"negotiation FAILURE code {BitConverter.ToUInt32(reply, 15)}"
                : $"{n} bytes: {Convert.ToHexString(reply, 0, n)}";

        // Who owns the far end of *this* connection? The row whose local port is the server's
        // and whose remote port is ours.
        uint owner = OwnerOfServerSide(port, local.Port);
        string verdict = owner == 0 ? "far end not found in the TCP table"
            : owner == termPid ? $"far end is pid {owner}, TermService's own process: genuine"
            : $"far end is pid {owner}, NOT TermService (pid {termPid})";
        return $"{answer}; {verdict}";
    }

    private static uint OwnerOfServerSide(int serverPort, int ourPort)
    {
        const int AF_INET = 2, TCP_TABLE_OWNER_PID_CONNECTIONS = 4;
        int size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            uint err = GetExtendedTcpTable(buffer, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
            if (err != 0) throw new InvalidOperationException($"GetExtendedTcpTable {err}");
            int count = Marshal.ReadInt32(buffer);
            for (int i = 0; i < count; i++)
            {
                IntPtr row = buffer + 4 + i * 24;
                int localPort = (ushort)IPAddress.NetworkToHostOrder((short)Marshal.ReadInt32(row, 8));
                int remotePort = (ushort)IPAddress.NetworkToHostOrder((short)Marshal.ReadInt32(row, 16));
                if (localPort == serverPort && remotePort == ourPort) return (uint)Marshal.ReadInt32(row, 20);
            }
            return 0;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // ---- Firewall ---------------------------------------------------------------------------

    private static string Firewall(int port)
    {
        Type type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2") ?? throw new InvalidOperationException("no HNetCfg.FwPolicy2");
        dynamic policy = Activator.CreateInstance(type)!;
        var lines = new List<string>();
        foreach (var (name, id) in new[] { ("Domain", 1), ("Private", 2), ("Public", 4) })
        {
            object enabled = type.InvokeMember("FirewallEnabled", System.Reflection.BindingFlags.GetProperty, null, (object)policy, [id])!;
            lines.Add($"{name} {(Convert.ToBoolean(enabled) ? "on" : "OFF")}");
        }
        int current = policy.CurrentProfileTypes;
        lines.Add($"current profile bits {current}");
        string wanted = port.ToString();
        foreach (dynamic rule in policy.Rules)
        {
            string? ports = rule.LocalPorts as string;
            if (rule.Direction != 1 || ports is null) continue; // 1 = inbound
            if (!ports.Split(',').Any(p => p.Trim() == wanted)) continue;
            lines.Add($"\n      rule \"{rule.Name}\": {(rule.Enabled ? "enabled" : "disabled")}, {(rule.Action == 1 ? "allow" : "BLOCK")}, protocol {rule.Protocol}, profiles {rule.Profiles}, remote {rule.RemoteAddresses}");
        }
        return string.Join("; ", lines);
    }

    // ---- Account ----------------------------------------------------------------------------

    private static string AccountKind(string user)
    {
        int err = NetUserGetInfo(null, user, 24, out IntPtr buffer);
        if (err != 0) return $"NetUserGetInfo {err} (2221 = not a local account: a domain or Entra account)";
        try
        {
            var info = Marshal.PtrToStructure<USER_INFO_24>(buffer);
            if (!info.internetIdentity) return "local account";
            string principal = Marshal.PtrToStringUni(info.principalName) ?? "";
            string provider = Marshal.PtrToStringUni(info.providerName) ?? "";
            return $"internet identity via {provider}: {Mask(principal)}";
        }
        finally { NetApiBufferFree(buffer); }
    }

    private static List<string> LocalGroups(string user)
    {
        const int LG_INCLUDE_INDIRECT = 1;
        var names = new List<string>();
        int err = NetUserGetLocalGroups(null, user, 0, LG_INCLUDE_INDIRECT, out IntPtr buffer, -1, out int read, out _);
        if (err != 0) { names.Add($"NetUserGetLocalGroups {err}"); return names; }
        try
        {
            for (int i = 0; i < read; i++)
                names.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, i * IntPtr.Size)) ?? "?");
        }
        finally { NetApiBufferFree(buffer); }
        return names;
    }

    private static string Mask(string principal)
    {
        int at = principal.IndexOf('@');
        return at > 1 ? principal[0] + "…" + principal[at..] : "…";
    }

    // ---- Shells -----------------------------------------------------------------------------

    private static IEnumerable<(string, string)> Shells()
    {
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string system = Environment.SystemDirectory;
        string pwsh = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
        yield return ("PowerShell 7 (Program Files)", File.Exists(pwsh) ? pwsh : "not found");
        using (var appPath = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe"))
            yield return ("PowerShell 7 (App Paths)", appPath?.GetValue(null) as string ?? "not found");
        string alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "pwsh.exe");
        yield return ("PowerShell 7 (Store alias, user-writable folder)", File.Exists(alias) ? alias : "not found");
        yield return ("Windows PowerShell", Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"));
        yield return ("Command Prompt", Path.Combine(system, "cmd.exe"));
        using (var git = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\GitForWindows"))
        {
            string? root = git?.GetValue("InstallPath") as string;
            yield return ("Git Bash", root is null ? "not found" : Path.Combine(root, "bin", "bash.exe"));
        }
        using var lxss = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
        if (lxss is null) { yield return ("WSL distros", "none registered"); yield break; }
        foreach (string id in lxss.GetSubKeyNames())
        {
            using var distro = lxss.OpenSubKey(id);
            yield return ("WSL distro", $"{distro?.GetValue("DistributionName")} (version {distro?.GetValue("Version")})");
        }
    }

    // ---- Plumbing ---------------------------------------------------------------------------

    private static void Section(string title) => Console.WriteLine($"\n== {title}");
    private static void Line(string label, object? value) => Console.WriteLine($"  {label}: {value ?? "(absent)"}");

    private static void Try(string label, Func<string> read)
    {
        try { Line(label, read()); }
        catch (Exception e) { Line(label, $"FAILED: {e.GetType().Name}: {e.Message}"); }
    }

    private static int IndexOfOrMax(string text, string value)
    {
        int i = text.IndexOf(value, StringComparison.OrdinalIgnoreCase);
        return i < 0 ? int.MaxValue : i;
    }

    private static string Run(string file, string arguments)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, file), arguments)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
        };
        using var process = Process.Start(info)!;
        string text = process.StandardOutput.ReadToEnd();
        process.WaitForExit(10000);
        return text;
    }

    private static void Check(uint error)
    {
        if (error != 0) throw new InvalidOperationException($"error {error}");
    }

    private static string SystemInformationBattery()
    {
        return GetSystemPowerStatus(out SYSTEM_POWER_STATUS s) ? ((s.BatteryFlag & 128) != 0 ? "no" : "yes") : "unknown";
    }

    private static SERVICE_STATUS_PROCESS QueryService(string name)
    {
        const uint SC_MANAGER_CONNECT = 1, SERVICE_QUERY_STATUS = 4;
        IntPtr manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (manager == IntPtr.Zero) throw new InvalidOperationException($"OpenSCManager {Marshal.GetLastWin32Error()}");
        try
        {
            IntPtr service = OpenService(manager, name, SERVICE_QUERY_STATUS);
            if (service == IntPtr.Zero) throw new InvalidOperationException($"OpenService {Marshal.GetLastWin32Error()}");
            try
            {
                if (!QueryServiceStatusEx(service, 0, out SERVICE_STATUS_PROCESS status, Marshal.SizeOf<SERVICE_STATUS_PROCESS>(), out _))
                    throw new InvalidOperationException($"QueryServiceStatusEx {Marshal.GetLastWin32Error()}");
                return status;
            }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(manager); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS_PROCESS
    {
        public uint dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode,
            dwCheckPoint, dwWaitHint, dwProcessId, dwServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct USER_INFO_24
    {
        [MarshalAs(UnmanagedType.Bool)] public bool internetIdentity;
        public uint flags;
        public IntPtr providerName;
        public IntPtr principalName;
        public IntPtr userSid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }

    [DllImport("slc.dll", CharSet = CharSet.Unicode)]
    private static extern int SLGetWindowsInformationDWORD(string name, out uint value);

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, uint reserved);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManager(string? machine, string? database, uint access);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr manager, string name, uint access);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(IntPtr service, int level, out SERVICE_STATUS_PROCESS status, int size, out int needed);

    [DllImport("advapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetUserGetInfo(string? server, string user, int level, out IntPtr buffer);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetUserGetLocalGroups(string? server, string user, int level, int flags, out IntPtr buffer, int preferredLength, out int read, out int total);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr buffer);

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadACValueIndex(IntPtr root, IntPtr scheme, ref Guid subgroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadDCValueIndex(IntPtr root, IntPtr scheme, ref Guid subgroup, ref Guid setting, out uint value);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
}
