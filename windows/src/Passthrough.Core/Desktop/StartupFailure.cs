using Passthrough.Core.Logging;

namespace Passthrough.Core.Desktop;

/// <summary>What the message box says when the app can't start (it then closes, so a later launch isn't blocked).</summary>
public static class StartupFailure
{
    public const string Caption = "Passthrough";

    public static string Message(Exception e, string logPath) => LogText.Redact(
        "Passthrough couldn't start.\n\n" +
        $"{e.GetType().Name}: {e.Message}\n\n" +
        $"Details are in {logPath}. Passthrough will now close; start it again once the problem is fixed.");
}
