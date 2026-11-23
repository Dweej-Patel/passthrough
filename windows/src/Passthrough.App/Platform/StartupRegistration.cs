using Microsoft.Win32;
using Passthrough.Core.Desktop;
using Passthrough.Windows.Setup;

namespace Passthrough.App.Platform;

/// <summary>
/// Start at login, through <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>, value <c>Passthrough</c>. The value
/// rules (quoting, the launcher once Remote access is installed, repair) are Core's <see cref="StartAtLogin"/>.
/// </summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Passthrough";

    /// <summary>The installed launcher (the service's exe at the path that never changes), when Remote access is installed.</summary>
    private static string? Launcher() =>
        WindowsMachineRegistry.Read() is { InstallFolder: { Length: > 0 } folder } && Path.GetDirectoryName(folder.TrimEnd('\\')) is { } root
            ? Path.Combine(root, Passthrough.Core.Setup.ServiceDefinition.ExeName) : null;

    /// <summary>Whether this process is the installed copy (it runs from the install folder Remote access recorded).</summary>
    public static bool IsInstalledCopy() =>
        WindowsMachineRegistry.Read() is { InstallFolder: { Length: > 0 } folder } && Environment.ProcessPath is { } exe
        && string.Equals(Path.GetDirectoryName(exe), folder.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    /// <summary>On only when the entry starts this exe or the installed launcher; an entry left by a moved or deleted build reads as off.</summary>
    public static bool IsEnabled() => StartAtLogin.IsEnabled(Read(), Environment.ProcessPath, Launcher());

    public static void SetEnabled(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on)
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("The app's path is unknown.");
            key.SetValue(ValueName, StartAtLogin.EnabledValue(exe, Launcher()));
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    /// <summary>At launch: an enabled entry is pointed at the right copy (see <see cref="StartAtLogin.Repair"/>). True when it was rewritten.</summary>
    public static bool RepairAtLaunch()
    {
        if (StartAtLogin.Repair(Read(), Environment.ProcessPath, Launcher(), IsInstalledCopy()) is not { } value) return false;
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        key.SetValue(ValueName, value);
        return true;
    }

    private static string? Read()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(ValueName) as string;
    }
}
