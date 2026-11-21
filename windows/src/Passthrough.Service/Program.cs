using System.Diagnostics;
using System.Runtime.InteropServices;
using Passthrough.Core.Setup;
using Passthrough.Windows.Service;
using Passthrough.Windows.Setup;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace Passthrough.Service;

/// <summary>
/// <c>Passthrough.Service.exe</c>: <c>--service</c> (started by Windows), <c>--launch</c> (Start at login and the Start
/// menu: starts the installed app), and the elevated verbs. Nothing else.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        // Before anything native loads: System32 only, never the folder this exe sits in.
        SetDefaultDllDirectories(LoadLibrarySearchSystem32);
        var verb = args.FirstOrDefault() ?? "";
        try
        {
            return verb switch
            {
                "--service" => RunService(),
                ServiceDefinition.LaunchVerb => Launch(args[1..]),
                "--install" or "--update" or "--off" or "--remove" or "--configure" => Elevated.Run(args),
                _ => Usage(),
            };
        }
        catch (Exception e) when (verb != "--service")
        {
            Console.Error.WriteLine($"{e.GetType().Name}: {e.Message}");
            return 3;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("Passthrough's background service. Turn Remote access on or off in Passthrough's settings.");
        return 64;
    }

    private static int RunService()
    {
        var service = new BackgroundService();
        return ServiceHost.Run(ServiceDefinition.Name, service.RunAsync, service.OnControl) ? 0 : Usage();
    }

    /// <summary>Starts the installed app as whoever ran this (Start at login, the Start menu); passes the rest on.</summary>
    private static int Launch(string[] rest)
    {
        if (WindowsMachineRegistry.Read() is not { } installed) return 2;
        var app = Path.Combine(installed.InstallFolder, ServiceDefinition.AppExeName);
        // Only a copy under this exe's own folder (administrators-only), never wherever the registry might point.
        var root = Path.GetDirectoryName(Environment.ProcessPath)!;
        if (!Path.GetFullPath(app).StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(app)) return 2;
        var start = new ProcessStartInfo(app) { UseShellExecute = false, WorkingDirectory = installed.InstallFolder };
        foreach (var argument in rest) start.ArgumentList.Add(argument);
        using var _ = Process.Start(start);
        return 0;
    }

    private const uint LoadLibrarySearchSystem32 = 0x00000800;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetDefaultDllDirectories(uint flags);
}
