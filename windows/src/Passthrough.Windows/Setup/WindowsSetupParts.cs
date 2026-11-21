using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;
using Passthrough.Core.Setup;

namespace Passthrough.Windows.Setup;

/// <summary>Windows Firewall through its COM API (<c>HNetCfg.FwPolicy2</c>), the source of truth for Passthrough's rules.</summary>
public sealed class WindowsFirewallRules : IFirewallRules
{
    private const int ProfilesAll = 0x7FFFFFFF, DirectionIn = 1, ActionAllow = 1;

    private static dynamic Policy() =>
        Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: true)!)!;

    public IReadOnlyList<FirewallRule> InGroup(string group = ServiceDefinition.FirewallGroup)
    {
        var found = new List<FirewallRule>();
        foreach (dynamic rule in Policy().Rules)
        {
            if (rule.Grouping as string != group) continue;
            found.Add(new FirewallRule((string)rule.Name, (int)rule.Protocol, (string?)rule.LocalPorts ?? "*", (string?)rule.ApplicationName ?? "",
                (string?)rule.ServiceName, (string?)rule.RemoteAddresses ?? "*", (bool)rule.Enabled, group, (int)rule.Action == 0));
        }
        return found;
    }

    public void Add(FirewallRule rule)
    {
        dynamic created = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule", throwOnError: true)!)!;
        created.Name = rule.Name;
        created.Grouping = rule.Group;
        created.Description = "Added by Passthrough's Remote access. Turn it off in Passthrough's settings.";
        created.Direction = DirectionIn;
        created.Action = rule.Block ? 0 : ActionAllow;
        created.Protocol = rule.Protocol;
        if (rule.LocalPorts != "*") created.LocalPorts = rule.LocalPorts;
        if (rule.Program.Length > 0) created.ApplicationName = rule.Program;
        if (rule.Service is { } service) created.ServiceName = service;
        created.Profiles = ProfilesAll;
        created.RemoteAddresses = rule.RemoteAddresses;
        created.EdgeTraversal = false;
        created.Enabled = rule.Enabled;
        Policy().Rules.Add(created);
    }

    public void Remove(string name, string group = ServiceDefinition.FirewallGroup)
    {
        var rules = Policy().Rules;
        // Rules.Remove takes the first with the name; ours are removed until none is left in the group.
        for (var i = 0; i < 16 && InGroup(group).Any(r => r.Name == name); i++) rules.Remove(name);
    }

    public void SetEnabled(string name, bool enabled)
    {
        foreach (dynamic rule in Policy().Rules)
            if (rule.Grouping as string == ServiceDefinition.FirewallGroup && rule.Name as string == name) rule.Enabled = enabled;
    }
}

/// <summary><c>HKLM\SOFTWARE\Passthrough</c> (64-bit view): administrators write, everyone reads (inherited from SOFTWARE).</summary>
public sealed class WindowsMachineRegistry : IMachineRegistry
{
    private static RegistryKey Root => RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);

    public bool Exists
    {
        get
        {
            using var key = Root.OpenSubKey(ServiceDefinition.RegistryKey);
            return key is not null;
        }
    }

    public IReadOnlyDictionary<string, string> Values()
    {
        using var key = Root.OpenSubKey(ServiceDefinition.RegistryKey);
        if (key is null) return new Dictionary<string, string>();
        return key.GetValueNames().ToDictionary(n => n, n => Convert.ToString(key.GetValue(n), System.Globalization.CultureInfo.InvariantCulture) ?? "");
    }

    public void Set(string name, string value)
    {
        using var key = Root.CreateSubKey(ServiceDefinition.RegistryKey);
        key.SetValue(name, value, RegistryValueKind.String);
    }

    public void SetNumber(string name, int value)
    {
        using var key = Root.CreateSubKey(ServiceDefinition.RegistryKey);
        key.SetValue(name, value, RegistryValueKind.DWord);
    }

    public void DeleteValue(string name)
    {
        using var key = Root.OpenSubKey(ServiceDefinition.RegistryKey, writable: true);
        key?.DeleteValue(name, throwOnMissingValue: false);
    }

    public void DeleteKey() => Root.DeleteSubKeyTree(ServiceDefinition.RegistryKey, throwOnMissingSubKey: false);

    /// <summary>An update or repair is stopping the service (it tells phones nothing; they reconnect).</summary>
    public static bool IsUpdating()
    {
        try
        {
            using var key = Root.OpenSubKey(ServiceDefinition.RegistryKey);
            return key?.GetValue("Updating") is 1;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return false; }
    }

    /// <summary>What every account reads: where the install is and whether Remote access is on. Null when not installed.</summary>
    public static (string InstallFolder, string Build, bool Enabled, int PipeProtocol)? Read()
    {
        try
        {
            using var key = Root.OpenSubKey(ServiceDefinition.RegistryKey);
            if (key?.GetValue("InstallFolder") is not string folder) return null;
            return (folder, key.GetValue("Build") as string ?? "", key.GetValue("Enabled") is 1, key.GetValue("PipeProtocol") as int? ?? 0);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return null; }
    }
}

/// <summary>Folders and files with their security set at creation; nothing followed through a reparse point.</summary>
public sealed class WindowsSecuredFiles : ISecuredFiles
{
    private static readonly SecurityIdentifier[] TrustedOwners =
    [
        new(WellKnownSidType.BuiltinAdministratorsSid, null),
        new(WellKnownSidType.LocalSystemSid, null),
        new(ServiceDefinition.Sid),
        new("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"), // TrustedInstaller
    ];

    private const FileSystemRights WriteRights = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteExtendedAttributes
        | FileSystemRights.WriteAttributes | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions
        | FileSystemRights.TakeOwnership;

    /// <summary>
    /// Trusted only when it is a real folder, owned by a trusted account, writable by nobody else, and the same holds
    /// for everything in it: anyone can make a folder under ProgramData, and a handle opened while it was theirs would
    /// outlive a repair (so it is refused, not repaired).
    /// </summary>
    public FolderCheck Check(string folder)
    {
        if (!Directory.Exists(folder) && !File.Exists(folder)) return FolderCheck.Missing;
        try
        {
            foreach (var entry in Enumerable.Repeat(folder, 1).Concat(Directory.EnumerateFileSystemEntries(folder, "*", new EnumerationOptions
                     { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })))
            {
                var info = new FileInfo(entry);
                if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return FolderCheck.Planted;
                FileSystemSecurity security = info.Attributes.HasFlag(FileAttributes.Directory) ? new DirectoryInfo(entry).GetAccessControl() : info.GetAccessControl();
                if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !TrustedOwners.Contains(owner)) return FolderCheck.Planted;
                foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                {
                    if (rule.AccessControlType != AccessControlType.Allow || (rule.FileSystemRights & WriteRights) == 0) continue;
                    if (rule.IdentityReference is SecurityIdentifier sid && (TrustedOwners.Contains(sid) || sid.IsWellKnown(WellKnownSidType.CreatorOwnerSid))) continue;
                    return FolderCheck.Planted;
                }
            }
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return FolderCheck.Planted; }
        return FolderCheck.Trusted;
    }

    public void CreateFolder(string folder, string sddl)
    {
        var security = new DirectorySecurity();
        security.SetSecurityDescriptorSddlForm(sddl);
        // Made with its security in the one call: there's no moment another account could open it.
        new DirectoryInfo(folder).Create(security);
    }

    public void SetSecurity(string folder, string sddl)
    {
        var security = new DirectorySecurity();
        security.SetSecurityDescriptorSddlForm(sddl);
        new DirectoryInfo(folder).SetAccessControl(security);
    }

    public bool FolderExists(string folder) => Directory.Exists(folder);

    public bool FileExists(string path) => File.Exists(path);

    public IReadOnlyList<string> Folders(string folder) => Directory.Exists(folder) ? Directory.GetDirectories(folder) : [];

    public byte[] ReadLocked(string path)
    {
        if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new SetupException($"{Path.GetFileName(path)} is a link, not a file. Build it again.");
        // FileShare.Read: nobody can write it while it is read and hashed.
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        return bytes;
    }

    public void WriteNew(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
    }

    public void Write(string path, byte[] bytes)
    {
        var temp = path + "." + Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4)) + ".tmp";
        using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }

    public void DeleteFile(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }

    public bool DeleteFolder(string folder)
    {
        if (!Directory.Exists(folder)) return true;
        try
        {
            Directory.Delete(folder, recursive: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // In use (another account's tray app runs from it): each file, then each folder, at the next restart.
            foreach (var file in SafeEntries(folder, files: true)) TryDeleteOrQueue(file);
            foreach (var sub in SafeEntries(folder, files: false).OrderByDescending(p => p.Length)) TryDeleteOrQueue(sub, directory: true);
            TryDeleteOrQueue(folder, directory: true);
            return !Directory.Exists(folder);
        }
    }

    private static IEnumerable<string> SafeEntries(string folder, bool files)
    {
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint };
            return files ? Directory.GetFiles(folder, "*", options) : Directory.GetDirectories(folder, "*", options);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    private static void TryDeleteOrQueue(string path, bool directory = false)
    {
        try
        {
            if (directory) Directory.Delete(path); else File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            MoveFileEx(path, null, MoveFileDelayUntilReboot);
        }
    }

    private const int MoveFileDelayUntilReboot = 4;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "MoveFileExW")]
    private static extern bool MoveFileEx(string existing, string? replacement, int flags);
}

/// <summary>Start menu shortcuts, through the shell's own COM object.</summary>
public sealed class WindowsShortcuts : IShortcuts
{
    public bool Exists(string path) => File.Exists(path);

    public void Create(string path, string target, string arguments, string icon)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!)!;
        dynamic link = shell.CreateShortcut(path);
        link.TargetPath = target;
        link.Arguments = arguments;
        link.IconLocation = icon + ",0";
        link.Description = "Passthrough";
        link.WorkingDirectory = Path.GetDirectoryName(target);
        link.Save();
    }

    public void Delete(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }
}

/// <summary>This PC, for the elevated verbs.</summary>
public static class WindowsSetup
{
    public static SetupMachine Machine() => new()
    {
        ProgramFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Passthrough"),
        DataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Passthrough"),
        ShortcutPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), ServiceDefinition.ShortcutName),
        WindowsBuild = Environment.OSVersion.Version.Build,
    };

    public static SetupSystem System() => new()
    {
        Service = new WindowsServiceControl(),
        Firewall = new WindowsFirewallRules(),
        Registry = new WindowsMachineRegistry(),
        Files = new WindowsSecuredFiles(),
        Shortcuts = new WindowsShortcuts(),
        Machine = Machine(),
    };

    /// <summary>This process runs elevated and as a member of Administrators.</summary>
    public static bool IsElevatedAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator) && Shell.UserEnvironment.IsElevated();
    }

    internal static Win32Exception LastError(string what) => new(Marshal.GetLastWin32Error(), what);
}
