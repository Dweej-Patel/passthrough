namespace Passthrough.Core.Session;

/// <summary>How an attached phone stands with this PC.</summary>
public enum PhoneState
{
    /// <summary>
    /// No pairing; for the active phone, it waits for the code shown on the phone (its channel open, or being reopened
    /// at once after the phone closed an idle one or locked a code, so the code box stays up).
    /// </summary>
    NotPaired,

    /// <summary>The active phone's channel is opening, or about to be opened again (the entry's message says why it dropped).</summary>
    Connecting,

    /// <summary>Paired: for the active phone, proved on the open channel; for another phone, a token is stored for it.</summary>
    Paired,

    /// <summary>A code went to the active phone and has not been answered yet.</summary>
    Pairing,

    /// <summary>The active phone's channel failed in a way retrying cannot fix (see the entry's message).</summary>
    Failed,

    /// <summary>An iPad: it never carries the PC's internet, and pairs only once Remote shell exists.</summary>
    RemoteOnlyLater,
}
