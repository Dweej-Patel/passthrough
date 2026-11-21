using Microsoft.Win32;
using Passthrough.Core.Desktop;

namespace Passthrough.App.Platform;

/// <summary>
/// Start at login, through <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>, value <c>Passthrough</c>. The value
/// rules (quoting, "does it start this exe", repair) are Core's <see cref="StartAtLogin"/>.
/// </summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Passthrough";

    /// <summary>On only when the entry starts this exe; an entry left by a moved or deleted build reads as off.</summary>
    public static bool IsEnabled() => StartAtLogin.PointsAt(Read(), Environment.ProcessPath);

    public static void SetEnabled(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on)
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("The app's path is unknown.");
            key.SetValue(ValueName, StartAtLogin.Command(exe));
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    /// <summary>At launch: an enabled entry that starts another exe (the app moved or was rebuilt elsewhere) is pointed at this one. True when it was rewritten.</summary>
    public static bool RepairAtLaunch()
    {
        if (StartAtLogin.Repair(Read(), Environment.ProcessPath) is not { } value) return false;
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
