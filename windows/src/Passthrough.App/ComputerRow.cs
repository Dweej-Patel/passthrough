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
}
