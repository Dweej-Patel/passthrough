namespace Passthrough.Core.Setup;

/// <summary>A setup step could not do what it must; <see cref="Message"/> is the sentence the person sees.</summary>
public sealed class SetupException(string message, Exception? inner = null) : Exception(message, inner);

public enum ServiceStart { Automatic, Manual, Disabled }

/// <summary>What the service is set to run, as the Service Control Manager has it.</summary>
public sealed record ServiceConfig(string BinaryPath, ServiceStart StartType);

/// <summary>The Service Control Manager, for the elevated verbs.</summary>
public interface IServiceControl
{
    /// <summary>The service's configuration; null when it isn't installed.</summary>
    ServiceConfig? Query();

    bool IsRunning();

    /// <summary>
    /// Creates the service, or changes the existing one, to run <paramref name="binaryPath"/> with everything else in
    /// <see cref="ServiceDefinition"/> (account, SID type, privileges, recovery, pre-shutdown, its security).
    /// </summary>
    void Configure(string binaryPath, ServiceStart start, IReadOnlyList<string> allowedAccounts);

    void SetStartType(ServiceStart start);

    /// <summary>Sets only the service's security (the allowed accounts changed).</summary>
    void SetSecurity(IReadOnlyList<string> allowedAccounts);

    void Delete();

    /// <summary>Starts it and waits until it runs; throws <see cref="SetupException"/> with why it stopped.</summary>
    void Start(TimeSpan wait);

    /// <summary>Stops it and waits until it has stopped (nothing when it isn't running).</summary>
    void Stop(TimeSpan wait);

    /// <summary>Sends a user-defined control (128 to 255); false when it isn't running.</summary>
    bool SendControl(int code);

    /// <summary>
    /// Deletes the service account's profile (its folder and its ProfileList entry), and with it the service's TLS key
    /// and DPAPI keys, so a store left behind can't be opened. Only once the service is deleted. False when there was none.
    /// </summary>
    bool DeleteProfile();
}

public interface IFirewallRules
{
    /// <summary>The rules in <see cref="ServiceDefinition.FirewallGroup"/>, by name.</summary>
    IReadOnlyList<FirewallRule> InGroup();

    void Add(FirewallRule rule);

    /// <summary>Removes every rule of the group with this name.</summary>
    void Remove(string name);

    void SetEnabled(string name, bool enabled);
}

/// <summary><c>HKLM\SOFTWARE\Passthrough</c>: what every account may read (where the install is, whether it is on).</summary>
public interface IMachineRegistry
{
    bool Exists { get; }

    /// <summary>Every value, as strings (DWORDs as their number).</summary>
    IReadOnlyDictionary<string, string> Values();

    void Set(string name, string value);

    void SetNumber(string name, int value);

    void DeleteValue(string name);

    void DeleteKey();
}

/// <summary>Whether a folder Setup is about to use may be trusted.</summary>
public enum FolderCheck
{
    Missing,
    /// <summary>A real folder owned by Administrators, SYSTEM or the service.</summary>
    Trusted,
    /// <summary>A reparse point, or owned by anyone else (any user can make a folder under ProgramData): never used, never deleted.</summary>
    Planted,
}

/// <summary>Folders and files, with their security. Paths are absolute.</summary>
public interface ISecuredFiles
{
    /// <summary>The folder, and (when it exists) every folder and file in it, judged as <see cref="FolderCheck"/>.</summary>
    FolderCheck Check(string folder);

    /// <summary>Creates the folder with <paramref name="sddl"/> as its security from the start.</summary>
    void CreateFolder(string folder, string sddl);

    /// <summary>Replaces the folder's security (and what inherits from it).</summary>
    void SetSecurity(string folder, string sddl);

    bool FolderExists(string folder);

    bool FileExists(string path);

    /// <summary>The folders directly in <paramref name="folder"/>.</summary>
    IReadOnlyList<string> Folders(string folder);

    /// <summary>Reads the whole file while denying writers, so what is hashed is what is copied.</summary>
    byte[] ReadLocked(string path);

    /// <summary>Writes a new file (its folders made as needed); fails if it exists.</summary>
    void WriteNew(string path, byte[] bytes);

    /// <summary>Writes a file whole, replacing it (temp file, flush, rename).</summary>
    void Write(string path, byte[] bytes);

    void DeleteFile(string path);

    /// <summary>Deletes the folder and everything in it; what is in use is queued for deletion at the next restart. True when all of it went now.</summary>
    bool DeleteFolder(string folder);
}

public interface IShortcuts
{
    bool Exists(string path);

    /// <summary>A shortcut that runs <paramref name="target"/> with <paramref name="arguments"/>, its icon from <paramref name="icon"/>.</summary>
    void Create(string path, string target, string arguments, string icon);

    void Delete(string path);
}

/// <summary>Where the install goes and what Windows is, for the plans.</summary>
public sealed record SetupMachine
{
    /// <summary><c>%ProgramFiles%\Passthrough</c>.</summary>
    public required string ProgramFolder { get; init; }
    /// <summary><c>%ProgramData%\Passthrough</c>.</summary>
    public required string DataFolder { get; init; }
    /// <summary>The Start menu shortcut every account sees.</summary>
    public required string ShortcutPath { get; init; }
    public required int WindowsBuild { get; init; }

    public string StateFile => WinPath.Join(DataFolder, ServiceDefinition.StateFileName);
    public string StoreFolder => WinPath.Join(DataFolder, "store");
    public string LogsFolder => WinPath.Join(DataFolder, "logs");
    /// <summary>The service's exe at the path that never changes (<see cref="ServiceDefinition.LaunchVerb"/>).</summary>
    public string ServiceExe => ServiceDefinition.ServiceExe(ProgramFolder);
}

/// <summary>Everything a step may touch.</summary>
public sealed class SetupSystem
{
    public required IServiceControl Service { get; init; }
    public required IFirewallRules Firewall { get; init; }
    public required IMachineRegistry Registry { get; init; }
    public required ISecuredFiles Files { get; init; }
    public required IShortcuts Shortcuts { get; init; }
    public required SetupMachine Machine { get; init; }
    public TimeProvider Time { get; init; } = TimeProvider.System;
    /// <summary>Random hex for new folder names (tests fix it).</summary>
    public Func<string> RandomHex { get; init; } = () => Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4));
}
