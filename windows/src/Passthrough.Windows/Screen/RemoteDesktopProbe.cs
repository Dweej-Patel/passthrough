using System.Runtime.InteropServices;
using Microsoft.Win32;
using Passthrough.Core.Screen;
using Passthrough.Core.Setup;
using Passthrough.Windows.Setup;

namespace Passthrough.Windows.Screen;

/// <summary>
/// Reads this PC's Remote Desktop (stage 5 plan, section 1) into <see cref="RemoteDesktopFacts"/>: the registry, the
/// licence value, TermService, and Windows Firewall through its COM API. Everything here is readable without
/// elevation, so the service reads it. A failed read sets <see cref="RemoteDesktopFacts.ReadFailed"/>, which the
/// exposure check treats as open.
/// </summary>
public static class RemoteDesktopProbe
{
    public const string BlockTcpRule = ServiceDefinition.BlockTcpRuleName;
    public const string BlockUdpRule = ServiceDefinition.BlockUdpRuleName;
    private const string TerminalServer = @"SYSTEM\CurrentControlSet\Control\Terminal Server";
    private const string RdpTcp = TerminalServer + @"\WinStations\RDP-Tcp";
    private const string Policy = @"SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services";
    private const string FirewallPolicies = @"SOFTWARE\Policies\Microsoft\WindowsFirewall";

    public static RemoteDesktopFacts Read()
    {
        var failed = false;
        using var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        int? Dword(string key, string name)
        {
            try
            {
                using var k = hklm.OpenSubKey(key);
                return k?.GetValue(name) is int v ? v : null;
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { failed = true; return null; }
        }
        var policyDeny = Dword(Policy, "fDenyTSConnections");
        var policyNla = Dword(Policy, "UserAuthentication");
        var nla = policyNla ?? Dword(RdpTcp, "UserAuthentication");
        var service = new WindowsServiceControl("TermService");
        (uint State, uint ProcessId, uint ExitCode)? status = null;
        ServiceStart? start = null;
        try
        {
            status = service.Status();
            start = service.Query()?.StartType;
        }
        catch (System.ComponentModel.Win32Exception) { failed = true; }
        var port = Dword(RdpTcp, "PortNumber") is { } p and > 0 and < 65536 ? p : 3389;
        var firewall = FirewallFacts(port, ref failed);
        bool? localRulesIgnored = false;
        foreach (var profile in new[] { "DomainProfile", "StandardProfile", "PublicProfile" })
            if (Dword($@"{FirewallPolicies}\{profile}", "AllowLocalPolicyMerge") == 0) localRulesIgnored = true;
        return new RemoteDesktopFacts
        {
            EditionMayHost = MayHost(),
            PolicyDenies = policyDeny is null ? null : policyDeny != 0,
            Denied = Dword(TerminalServer, "fDenyTSConnections") != 0,
            Port = port,
            NlaRequired = nla is null ? null : nla != 0,
            ServiceRunning = status?.State == 4,
            ServiceDisabled = start == ServiceStart.Disabled,
            FirewallOnEveryProfile = firewall.OnEveryProfile,
            BlockRulesIntact = firewall.BlockRulesIntact,
            AllowRuleForPort = firewall.AllowRule,
            OverridingAllowRule = firewall.OverridingAllowRule,
            FirewallManagedElsewhere = firewall.ManagedElsewhere,
            LocalRulesIgnored = localRulesIgnored,
            ReadFailed = failed,
        };
    }

    /// <summary>TermService's process, running; null when it isn't.</summary>
    public static int? TermServiceProcess() =>
        new WindowsServiceControl("TermService").Status() is { State: 4, ProcessId: var pid and > 0 } ? (int)pid : null;

    /// <summary>The licence value (1 on Pro and up); from the edition when the call fails.</summary>
    private static bool? MayHost()
    {
        if (SLGetWindowsInformationDWORD("TerminalServices-RemoteConnectionManager-AllowRemoteConnections", out var value) == 0) return value != 0;
        try
        {
            using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            return key?.GetValue("EditionID") is string edition && edition.StartsWith("Core", StringComparison.OrdinalIgnoreCase) ? false : null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }

    private sealed record Firewall(bool? OnEveryProfile, bool? BlockRulesIntact, bool? AllowRule, bool? OverridingAllowRule, bool? ManagedElsewhere);

    private const int ProfilesAll = 0x7FFFFFFF, Inbound = 1, Block = 0, Allow = 1;

    private static Firewall FirewallFacts(int port, ref bool failed)
    {
        try
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: true)!;
            dynamic policy = Activator.CreateInstance(type)!;
            var on = new[] { 1, 2, 4 }.All(profile =>
                Convert.ToBoolean(type.InvokeMember("FirewallEnabled", System.Reflection.BindingFlags.GetProperty, null, (object)policy, [profile])));
            var managedElsewhere = (int)policy.LocalPolicyModifyState != 0;
            try
            {
                dynamic products = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwProducts", throwOnError: true)!)!;
                if ((int)products.Count > 0) managedElsewhere = true;
            }
            catch (COMException) { }
            var wanted = port.ToString(System.Globalization.CultureInfo.InvariantCulture);
            bool tcpBlock = false, udpBlock = false, allow = false, overriding = false;
            foreach (dynamic rule in policy.Rules)
            {
                if ((int)rule.Direction != Inbound) continue;
                string name = rule.Name;
                if (name is BlockTcpRule or BlockUdpRule)
                {
                    var intact = (bool)rule.Enabled && (int)rule.Action == Block && ((int)rule.Profiles & 7) == 7 && (string?)rule.LocalPorts == wanted
                        && string.IsNullOrEmpty((string?)rule.ApplicationName) && string.IsNullOrEmpty((string?)rule.ServiceName)
                        && (string?)rule.RemoteAddresses is null or "*" && (string?)rule.LocalAddresses is null or "*";
                    if (name == BlockTcpRule && (int)rule.Protocol == 6) tcpBlock |= intact;
                    if (name == BlockUdpRule && (int)rule.Protocol == 17) udpBlock |= intact;
                    continue;
                }
                if (!(bool)rule.Enabled || (int)rule.Action != Allow) continue;
                var ports = (string?)rule.LocalPorts;
                if (ports is not ("*" or null) && !ports.Split(',').Any(x => x.Trim() == wanted)) continue;
                if (ports is "*" or null && (int)rule.Protocol is not (6 or 17)) continue;
                if (ports is "*" or null && string.IsNullOrEmpty((string?)rule.ApplicationName) && string.IsNullOrEmpty((string?)rule.ServiceName)) { allow = true; }
                else if (ports is not ("*" or null)) allow = true;
                try { if ((int)rule.SecureFlags != 0) overriding = true; } catch (Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
            }
            return new Firewall(on, tcpBlock && udpBlock, allow, overriding && allow, managedElsewhere);
        }
        catch (Exception e) when (e is COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or TypeLoadException)
        {
            failed = true;
            return new Firewall(null, null, null, null, null);
        }
    }

    [DllImport("slc.dll", CharSet = CharSet.Unicode)]
    private static extern int SLGetWindowsInformationDWORD(string name, out int value);
}
