using Passthrough.Core.Trust;

namespace Passthrough.App;

/// <summary>Another computer this PC can reach, in the flyout's Your computers.</summary>
public sealed class ComputerRow(ReachableComputer computer)
{
    public ReachableComputer Computer { get; } = computer;
    public string Title => Computer.Credential.MacName;

    public string Detail => (Computer.HostKind == "windows" ? "PC" : "Mac")
        + (Computer.From is { } from ? $" · from {from}" : "")
        + (Computer.Scopes.Contains("shell") ? "" : " · screen only");

    public bool CanOpenShell => Computer.Scopes.Contains("shell");

    /// <summary>Forgets this PC's copy only: the other computer keeps its own settings, and a phone can share it again.</summary>
    public string RemoveQuestion => $"Remove {Title} from this PC? Its shells and screen can't be opened here until a phone shares it again.";
    public string RemoveName => $"Remove {Title}";
    public string ScreenName => $"Show {Title}'s screen";
    public string ShellName => $"New shell on {Title}";

    /// <summary>A Mac whose screen this PC was given: a PC offers only Remote Desktop, which this viewer doesn't show.</summary>
    public Microsoft.UI.Xaml.Visibility ScreenVisibility =>
        Computer.Scopes.Contains("screen") && Computer.HostKind != "windows" ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
}
