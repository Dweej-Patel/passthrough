using Passthrough.Core.Control;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>
/// Everything <see cref="HostSession"/> keeps for one attached device's control channel: its client, what the row
/// shows, and how it is retried. Touched only by work items on the session's loop.
/// </summary>
internal sealed class DeviceChannel(PhoneDevice device)
{
    public PhoneDevice Device { get; } = device;
    public ControlClient? Client;
    public PhoneState State = PhoneState.Connecting;
    public DeviceStatus? Status;
    public long Rx;
    public long Tx;
    public int Connections;
    public string? Message;
    /// <summary>The channel failed for good (failed proof, other version, token not saved, store unreadable): no reconnect until Try again or a re-attach.</summary>
    public bool Held;
    public ITimer? Reconnect;
    public long ReconnectSeq;
    /// <summary>Drops in a row since the last welcome; sets the back-off.</summary>
    public int Failures;
    /// <summary>Why the last retryable channel ended, shown while it is tried again; cleared by a welcome.</summary>
    public string? Reason;
    /// <summary>The last line logged for this device, so a repeat is not logged again.</summary>
    public string? LastLogged;
    /// <summary>When the current channel was opened (a <see cref="TimeProvider"/> timestamp).</summary>
    public long OpenedAt;
    /// <summary>The current channel uses a credential Forget removes: opened with a stored token, or paired on it.</summary>
    public bool HasCredential;
    /// <summary>The current channel has had its welcome: a code given to it now goes out at once.</summary>
    public bool Welcomed;
    /// <summary>
    /// A code typed for this device that has not left this PC: held by a channel that was never welcomed. When that
    /// channel fails to open, the next one is given it. Cleared by a welcome and when the channel is reset.
    /// </summary>
    public string? UnsentCode;

    public void ClearStatus() => (Status, Rx, Tx, Connections) = (null, 0, 0, 0);

    public void CancelReconnect()
    {
        ReconnectSeq++;
        Reconnect?.Dispose();
        Reconnect = null;
    }

    /// <summary>Forgets everything but the device: the next channel starts afresh.</summary>
    public void Reset()
    {
        CancelReconnect();
        Client = null;
        Held = false;
        State = PhoneState.Connecting;
        ClearStatus();
        Message = null;
        Reason = null;
        Failures = 0;
        LastLogged = null;
        UnsentCode = null;
    }
}
