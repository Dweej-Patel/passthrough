using System.Security.Principal;
using System.Text;
using Passthrough.Core.Logging;
using Passthrough.Core.Setup;
using Passthrough.Windows.Setup;

namespace Passthrough.Service;

/// <summary>
/// The elevated verbs (stage 4 plan, section 3): the only code that runs as administrator. They take no path: the
/// build is the folder this exe runs from, the destination is computed. Who asked comes from the setup pipe's other
/// end (<c>--report &lt;hex&gt;</c>), never an argument. Every step goes to the pipe and to <c>setup.log</c>.
/// </summary>
internal static class Elevated
{
    public static int Run(string[] args)
    {
        var verb = args[0];
        var report = Argument(args, "--report");
        var lines = new List<string>();
        SetupReporter? reporter = null;
        void Say(StepReport step)
        {
            lines.Add(SetupLines.Encode(step));
            reporter?.Report(step);
            if (reporter is null) Console.WriteLine(SetupLines.Encode(step));
        }
        SetupResult Finish(SetupResult result)
        {
            lines.Add(SetupLines.Encode(result));
            reporter?.Report(result);
            if (reporter is null) Console.WriteLine(SetupLines.Encode(result));
            WriteLog(verb, lines);
            reporter?.Dispose();
            return result;
        }
        SetupResult Refuse(string why) => Finish(new SetupResult { Result = SetupResult.Failed, FailedStep = "check", Error = why, Refused = true, Undone = true });

        string? asking;
        if (report is not null)
        {
            reporter = SetupReporter.Connect(report);
            if (reporter is null) return Refuse("Couldn't tell which account asked.").ExitCode;
            asking = reporter.AskingAccount.Value;
        }
        else
        {
            // Run by hand from an administrator's prompt (or CI): that account is the one asking.
            using var me = WindowsIdentity.GetCurrent();
            asking = me.User?.Value;
        }
        if (!WindowsSetup.IsElevatedAdministrator()) return Refuse("This needs an administrator.").ExitCode;

        using var mutex = new Mutex(initiallyOwned: false, @"Global\Passthrough.Setup");
        try
        {
            if (!mutex.WaitOne(0)) return Refuse("Passthrough is already being set up. Wait for it to finish.").ExitCode;
        }
        catch (AbandonedMutexException) { } // an earlier run died; this one owns it now

        var system = WindowsSetup.System();
        var source = Path.GetDirectoryName(Environment.ProcessPath)!;
        // Only --install and --update take a build from where they were started. The others run from the installed
        // copy (administrators-only), so nothing a user could have changed runs as administrator for them.
        if (verb is not ("--install" or "--update") && system.Files.FileExists(system.Machine.ServiceExe)
            && !string.Equals(Path.GetFullPath(Environment.ProcessPath!), Path.GetFullPath(system.Machine.ServiceExe), StringComparison.OrdinalIgnoreCase))
            return Refuse("Run this from the installed copy of Passthrough.").ExitCode;

        IReadOnlyList<ISetupStep> plan;
        var continuePastFailure = false;
        switch (verb)
        {
            case "--install": plan = SetupPlans.InstallOrUpdate(update: false); break;
            case "--update": plan = SetupPlans.InstallOrUpdate(update: true); break;
            case "--off": plan = SetupPlans.TurnOff(); break;
            case "--remove": plan = SetupPlans.RemoveAll(); continuePastFailure = true; break;
            case "--configure":
                switch (args.ElementAtOrDefault(1))
                {
                    case "allow": plan = SetupPlans.AllowAccount(); break;
                    case "disallow" when args.ElementAtOrDefault(2) is { } sid && IsSid(sid): plan = SetupPlans.DisallowAccount(sid); break;
                    case "relay": plan = SetupPlans.ConfigureRelay(); break;
                    case "reset-identity": plan = SetupPlans.ResetIdentity(); break;
                    default: return Refuse("Unknown setting.").ExitCode;
                }
                break;
            default: return Refuse("Unknown verb.").ExitCode;
        }
        var context = new SetupContext
        {
            System = system, Source = source, AskingAccount = asking,
            RelayUrl = reporter?.Input.RelayUrl, RelayToken = reporter?.Input.RelayToken,
        };
        var result = Finish(SetupEngine.Run(plan, context, Say, continuePastFailure));
        mutex.ReleaseMutex();
        return result.ExitCode;
    }

    private static bool IsSid(string text)
    {
        try { _ = new SecurityIdentifier(text); return true; }
        catch (ArgumentException) { return false; }
    }

    private static string? Argument(string[] args, string name)
    {
        var i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    /// <summary><c>%ProgramData%\Passthrough\logs\setup.log</c>, when the folder is there (it isn't after a removal).</summary>
    private static void WriteLog(string verb, List<string> lines)
    {
        try
        {
            var logs = WindowsSetup.Machine().LogsFolder;
            if (!Directory.Exists(logs)) return;
            var path = Path.Combine(logs, "setup.log");
            if (new FileInfo(path) is { Exists: true, Length: > 1_000_000 }) File.Move(path, path + ".1", overwrite: true);
            var text = new StringBuilder();
            foreach (var line in lines) text.Append(DateTimeOffset.UtcNow.ToString("u")).Append(' ').Append(verb).Append(' ').AppendLine(LogText.Redact(line));
            File.AppendAllText(path, text.ToString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
