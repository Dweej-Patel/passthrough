using Microsoft.Win32;
using Passthrough.Core.Shell;

namespace Passthrough.Windows.Shell;

/// <summary>Where <see cref="ShellCatalog"/> looks on this PC: System32, Program Files, and the registry's lists. Never PATH.</summary>
public sealed class ShellProbe : IShellProbe
{
    public string System32 => Environment.SystemDirectory;

    public string ProgramFiles => Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    /// <summary>
    /// The file is there and neither it nor its folder may be written by anyone but administrators and the system (B-7):
    /// a shell that anyone could replace, or plant a DLL beside, is never offered.
    /// </summary>
    public bool FileExists(string path) =>
        File.Exists(path) && OnlyAdministratorsWrite(new FileInfo(path).GetAccessControl())
        && Path.GetDirectoryName(path) is { } folder && OnlyAdministratorsWrite(new DirectoryInfo(folder).GetAccessControl());

    private const System.Security.AccessControl.FileSystemRights WriteRights =
        System.Security.AccessControl.FileSystemRights.WriteData | System.Security.AccessControl.FileSystemRights.AppendData
        | System.Security.AccessControl.FileSystemRights.WriteExtendedAttributes | System.Security.AccessControl.FileSystemRights.WriteAttributes
        | System.Security.AccessControl.FileSystemRights.Delete | System.Security.AccessControl.FileSystemRights.ChangePermissions
        | System.Security.AccessControl.FileSystemRights.TakeOwnership;

    internal static bool OnlyAdministratorsWrite(System.Security.AccessControl.FileSystemSecurity security)
    {
        var trusted = new[]
        {
            System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid, System.Security.Principal.WellKnownSidType.LocalSystemSid,
        }.Select(t => new System.Security.Principal.SecurityIdentifier(t, null)).ToList();
        // TrustedInstaller, which owns Windows' own files.
        trusted.Add(new System.Security.Principal.SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"));
        var rules = security.GetAccessRules(includeExplicit: true, includeInherited: true, typeof(System.Security.Principal.SecurityIdentifier));
        foreach (System.Security.AccessControl.FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != System.Security.AccessControl.AccessControlType.Allow) continue;
            if (rule.PropagationFlags.HasFlag(System.Security.AccessControl.PropagationFlags.InheritOnly)) continue;
            if ((rule.FileSystemRights & WriteRights) == 0) continue;
            if (!trusted.Contains((System.Security.Principal.SecurityIdentifier)rule.IdentityReference)) return false;
        }
        return true;
    }

    /// <summary>HKCU\…\Lxss: one key per distribution, its name in DistributionName; the default named by DefaultDistribution.</summary>
    public IReadOnlyList<string> WslDistributions()
    {
        try
        {
            using var lxss = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
            if (lxss is null) return [];
            var preferred = lxss.GetValue("DefaultDistribution") as string;
            var names = new List<(bool Default, string Name)>();
            foreach (var key in lxss.GetSubKeyNames())
            {
                using var distribution = lxss.OpenSubKey(key);
                if (distribution?.GetValue("DistributionName") is string name)
                    names.Add((string.Equals(key, preferred, StringComparison.OrdinalIgnoreCase), name));
            }
            return [.. names.OrderByDescending(n => n.Default).Select(n => n.Name)];
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return []; }
    }

    /// <summary>Git for Windows' installer records its folder here (machine-wide only: an administrator wrote it).</summary>
    public string? GitInstallFolder()
    {
        try
        {
            using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(@"SOFTWARE\GitForWindows");
            return key?.GetValue("InstallPath") as string;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }
}
