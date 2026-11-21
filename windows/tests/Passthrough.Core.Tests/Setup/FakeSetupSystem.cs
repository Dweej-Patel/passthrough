using Passthrough.Core.Setup;

namespace Passthrough.Core.Tests.Setup;

/// <summary>A whole PC for the setup plans, in memory: files, the service, the firewall, the registry, shortcuts.</summary>
internal sealed class FakePc : IServiceControl, IFirewallRules, IMachineRegistry, ISecuredFiles, IShortcuts
{
    public readonly Dictionary<string, byte[]> FileBytes = new(StringComparer.OrdinalIgnoreCase);
    public readonly Dictionary<string, string> FolderSddl = new(StringComparer.OrdinalIgnoreCase);
    public readonly HashSet<string> PlantedFolders = new(StringComparer.OrdinalIgnoreCase);
    public readonly HashSet<string> InUse = new(StringComparer.OrdinalIgnoreCase);
    public readonly List<FirewallRule> Rules = [];
    private Dictionary<string, string>? _registry;
    public readonly Dictionary<string, (string Target, string Arguments, string Icon)> Links = new(StringComparer.OrdinalIgnoreCase);
    public ServiceConfig? Service;
    public IReadOnlyList<string> ServiceAccounts = [];
    public bool Running;
    public bool HasProfile;
    public readonly List<string> Calls = [];
    /// <summary>The call (by name) that throws.</summary>
    public string? FailOn;
    public int StartFailures;

    private void Call(string name)
    {
        Calls.Add(name);
        if (FailOn == name) throw new SetupException($"{name} failed");
    }

    public SetupSystem System(int build = 26100) => new()
    {
        Service = this, Firewall = this, Registry = this, Files = this, Shortcuts = this,
        Machine = new SetupMachine
        {
            ProgramFolder = @"C:\Program Files\Passthrough",
            DataFolder = @"C:\ProgramData\Passthrough",
            ShortcutPath = @"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Passthrough.lnk",
            WindowsBuild = build,
        },
        Time = TimeProvider.System,
        RandomHex = () => $"{++_hex:x8}",
    };

    private int _hex;

    // MARK: A build to install

    public const string Source = @"D:\build\Passthrough";

    public FileManifest AddBuild(string build = "0.9.0+abc", bool selfContained = true, string source = Source)
    {
        var files = new List<FileManifest.Entry>();
        void Add(string path, string text)
        {
            var bytes = global::System.Text.Encoding.UTF8.GetBytes(text);
            FileBytes[WinPath.Join(source, path)] = bytes;
            files.Add(new FileManifest.Entry(path, bytes.Length, FileManifest.Hash(bytes)));
        }
        Add("Passthrough.exe", "app " + build);
        Add("Passthrough.Service.exe", "service " + build);
        if (selfContained) Add("coreclr.dll", "runtime");
        Add(@"x64\OpenConsole.exe", "console");
        var manifest = new FileManifest(build, files);
        FileBytes[WinPath.Join(source, "files.json")] = manifest.Encode();
        return manifest;
    }

    // MARK: IServiceControl

    public ServiceConfig? Query() => Service;
    public bool IsRunning() => Running;

    public void Configure(string binaryPath, ServiceStart start, IReadOnlyList<string> allowedAccounts)
    {
        Call("configure");
        Service = new ServiceConfig(binaryPath, start);
        ServiceAccounts = allowedAccounts;
    }

    public void SetStartType(ServiceStart start)
    {
        Call("start-type");
        Service = Service! with { StartType = start };
    }

    public void SetSecurity(IReadOnlyList<string> allowedAccounts)
    {
        Call("service-security");
        ServiceAccounts = allowedAccounts;
    }

    public void Delete()
    {
        Call("delete-service");
        Service = null;
        Running = false;
    }

    public void Start(TimeSpan wait)
    {
        Call("start");
        if (StartFailures > 0) { StartFailures--; throw new SetupException("didn't start"); }
        Running = true;
        HasProfile = true;
    }

    public void Stop(TimeSpan wait)
    {
        Call("stop");
        Running = false;
    }

    public bool SendControl(int code)
    {
        Call($"control {code}");
        return Running;
    }

    public bool DeleteProfile()
    {
        Call("delete-profile");
        var had = HasProfile;
        HasProfile = false;
        return had;
    }

    // MARK: IFirewallRules

    public IReadOnlyList<FirewallRule> InGroup() => [.. Rules];

    public void Add(FirewallRule rule)
    {
        Call("add-rule");
        Rules.Add(rule);
    }

    public void Remove(string name)
    {
        Call("remove-rule");
        Rules.RemoveAll(r => r.Name == name);
    }

    public void SetEnabled(string name, bool enabled)
    {
        Call("enable-rule");
        for (var i = 0; i < Rules.Count; i++) if (Rules[i].Name == name) Rules[i] = Rules[i] with { Enabled = enabled };
    }

    // MARK: IMachineRegistry

    public bool Exists => _registry is not null;
    public IReadOnlyDictionary<string, string> Values() => new Dictionary<string, string>(_registry ?? []);
    public IReadOnlyDictionary<string, string>? Registry => _registry;

    void IMachineRegistry.Set(string name, string value)
    {
        Call("registry");
        (_registry ??= [])[name] = value;
    }

    public void SetNumber(string name, int value)
    {
        Call("registry");
        (_registry ??= [])[name] = value.ToString(global::System.Globalization.CultureInfo.InvariantCulture);
    }

    public void DeleteValue(string name) => _registry?.Remove(name);

    public void DeleteKey()
    {
        Call("delete-registry");
        _registry = null;
    }

    // MARK: ISecuredFiles

    public FolderCheck Check(string folder) =>
        PlantedFolders.Contains(folder) ? FolderCheck.Planted : FolderExists(folder) ? FolderCheck.Trusted : FolderCheck.Missing;

    public void CreateFolder(string folder, string sddl)
    {
        Call($"create {WinPath.Name(folder)}");
        if (FolderExists(folder)) throw new IOException("exists");
        FolderSddl[folder] = sddl;
    }

    void ISecuredFiles.SetSecurity(string folder, string sddl) => FolderSddl[folder] = sddl;

    public bool FolderExists(string folder) =>
        FolderSddl.ContainsKey(folder) || PlantedFolders.Contains(folder)
        || FileBytes.Keys.Any(k => k.StartsWith(folder.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));

    public bool FileExists(string path) => FileBytes.ContainsKey(path);

    public IReadOnlyList<string> Folders(string folder)
    {
        var prefix = folder.TrimEnd('\\') + "\\";
        return [.. FileBytes.Keys.Concat(FolderSddl.Keys)
            .Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && k.Length > prefix.Length)
            .Select(k => k[prefix.Length..].Split('\\'))
            .Where(parts => parts.Length > 1 || FolderSddl.ContainsKey(prefix + parts[0]))
            .Select(parts => prefix + parts[0])
            .Distinct(StringComparer.OrdinalIgnoreCase)];
    }

    public byte[] ReadLocked(string path) => FileBytes.TryGetValue(path, out var bytes) ? bytes : throw new FileNotFoundException(path);

    public void WriteNew(string path, byte[] bytes)
    {
        Call("write-new");
        if (!FileBytes.TryAdd(path, bytes)) throw new IOException("exists");
    }

    public void Write(string path, byte[] bytes)
    {
        Call($"write {WinPath.Name(path)}");
        FileBytes[path] = bytes;
    }

    public void DeleteFile(string path) => FileBytes.Remove(path);

    public bool DeleteFolder(string folder)
    {
        Call($"delete {WinPath.Name(folder)}");
        if (InUse.Contains(folder)) return false;
        var prefix = folder.TrimEnd('\\') + "\\";
        foreach (var key in FileBytes.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList()) FileBytes.Remove(key);
        foreach (var key in FolderSddl.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || string.Equals(k, folder, StringComparison.OrdinalIgnoreCase)).ToList())
            FolderSddl.Remove(key);
        return true;
    }

    // MARK: IShortcuts

    bool IShortcuts.Exists(string path) => Links.ContainsKey(path);

    public void Create(string path, string target, string arguments, string icon)
    {
        Call("shortcut");
        Links[path] = (target, arguments, icon);
    }

    void IShortcuts.Delete(string path) => Links.Remove(path);

    /// <summary>Everything that would be left on the PC (for "remove leaves nothing").</summary>
    public string Leftovers() => string.Join(", ", new[]
    {
        Service is null ? null : "service",
        Rules.Count == 0 ? null : "rules",
        _registry is null ? null : "registry",
        Links.Count == 0 ? null : "shortcut",
        FileBytes.Keys.Any(k => !k.StartsWith(Source, StringComparison.OrdinalIgnoreCase)) ? "files" : null,
        FolderSddl.Count == 0 ? null : "folders",
        HasProfile ? "profile" : null,
    }.OfType<string>());
}
