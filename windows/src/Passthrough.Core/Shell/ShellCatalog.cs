using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Shell;

/// <summary>What the catalog may look at: fixed folders, the registry's lists, whether a file is there. Never PATH.</summary>
public interface IShellProbe
{
    /// <summary>The Windows System32 folder (<c>C:\Windows\System32</c>).</summary>
    string System32 { get; }

    /// <summary>The 64-bit Program Files folder.</summary>
    string ProgramFiles { get; }

    bool FileExists(string path);

    /// <summary>The account's WSL distributions, as the registry lists them (Lxss), default first.</summary>
    IReadOnlyList<string> WslDistributions();

    /// <summary>Git for Windows' install folder, as its installer recorded it, if any.</summary>
    string? GitInstallFolder();
}

/// <summary>
/// The shells this PC offers: built on the PC from fixed absolute paths, never from anything a phone sends. A phone
/// names one by its id (<see cref="HostShell.Id"/>) and gets that entry's program and arguments, or <c>bad_request</c>.
/// PowerShell 7 is the default when it is installed, else Windows PowerShell.
/// </summary>
public sealed class ShellCatalog
{
    /// <summary>A WSL distribution's name as registered: letters, digits, <c>.</c>, <c>_</c> and <c>-</c>, at most 64.</summary>
    public static bool IsValidDistribution(string name) =>
        name.Length is >= 1 and <= 64 && char.IsAsciiLetterOrDigit(name[0])
        && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');

    private readonly List<(HostShell Shell, ShellCommand Command)> _entries;

    private ShellCatalog(List<(HostShell, ShellCommand)> entries) => _entries = entries;

    public IReadOnlyList<HostShell> Shells => [.. _entries.Select(e => e.Shell)];

    public HostShell? Default => _entries.Select(e => e.Shell).FirstOrDefault(s => s.Default == true);

    /// <summary>The shell for <paramref name="id"/> (null: the default). Throws <see cref="ShellException"/> for one this PC hasn't.</summary>
    public ShellCommand Resolve(string? id)
    {
        foreach (var (shell, command) in _entries)
            if (id is null ? shell.Default == true : string.Equals(shell.Id, id, StringComparison.Ordinal)) return command;
        throw new ShellException(ShellError.BadRequest, id is null ? "This PC has no shell to start." : "This PC doesn't have that shell.");
    }

    public static ShellCatalog Discover(IShellProbe probe)
    {
        var found = new List<(string Id, string Name, string Executable, string[] Arguments)>();
        void Add(string id, string name, string executable, params string[] arguments)
        {
            if (Path.IsPathFullyQualified(executable) && probe.FileExists(executable)) found.Add((id, name, executable, arguments));
        }
        Add("pwsh", "PowerShell", Path.Combine(probe.ProgramFiles, "PowerShell", "7", "pwsh.exe"), "-NoLogo");
        Add("powershell", "Windows PowerShell", Path.Combine(probe.System32, "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo");
        Add("cmd", "Command Prompt", Path.Combine(probe.System32, "cmd.exe"));
        var wsl = Path.Combine(probe.System32, "wsl.exe");
        if (probe.FileExists(wsl))
            foreach (var distribution in probe.WslDistributions().Where(IsValidDistribution).Distinct(StringComparer.OrdinalIgnoreCase))
                Add($"wsl:{distribution}", distribution, wsl, "-d", distribution, "--cd", "~");
        var git = new[] { probe.GitInstallFolder(), Path.Combine(probe.ProgramFiles, "Git") }
            .OfType<string>().Where(Path.IsPathFullyQualified)
            .Select(folder => Path.Combine(folder, "bin", "bash.exe"))
            .FirstOrDefault(probe.FileExists);
        if (git is not null) Add("git-bash", "Git Bash", git, "--login", "-i");

        var defaultId = found.Any(f => f.Id == "pwsh") ? "pwsh" : found.Any(f => f.Id == "powershell") ? "powershell" : found.FirstOrDefault().Id;
        return new ShellCatalog([.. found.Select(f => (
            new HostShell { Id = f.Id, Name = f.Name, Default = f.Id == defaultId ? true : null },
            new ShellCommand(f.Id, f.Executable, f.Arguments)))]);
    }
}
