using Microsoft.Win32;
using Passthrough.Core.Shell;

namespace Passthrough.Windows.Shell;

/// <summary>Where <see cref="ShellCatalog"/> looks on this PC: System32, Program Files, and the registry's lists. Never PATH.</summary>
public sealed class ShellProbe : IShellProbe
{
    public string System32 => Environment.SystemDirectory;

    public string ProgramFiles => Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    public bool FileExists(string path) => File.Exists(path);

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
