namespace Passthrough.Core.Pipe;

/// <summary>The service's tray apps, one per account: whose shells a phone reaches, and how to tell a tray app something.</summary>
public interface ITrayHosts
{
    /// <summary>The shells of <paramref name="account"/>, linked or not.</summary>
    PipeSessionHost HostFor(string account);

    /// <summary>Pushes an event to <paramref name="account"/>'s tray app, when it is linked.</summary>
    void Tell(string account, PipeAdminEvent e);

    void TellAll(PipeAdminEvent e);

    /// <summary>Every account's shells known so far.</summary>
    IReadOnlyList<PipeSessionHost> Hosts { get; }

    /// <summary>Fires when an account's tray app comes or goes, or its sessions or state change.</summary>
    event Action<PipeSessionHost>? Changed;
}
