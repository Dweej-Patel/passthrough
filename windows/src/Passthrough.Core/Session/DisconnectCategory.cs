namespace Passthrough.Core.Session;

/// <summary>Why a channel that can be retried ended, as far as the user and the log need to know. Carries no phone-supplied text.</summary>
public enum DisconnectCategory
{
    /// <summary>The phone closed the channel cleanly.</summary>
    PhoneClosed,

    /// <summary>The phone refused the connection: Passthrough isn't running on it.</summary>
    AppNotRunning,

    /// <summary>The phone stopped answering (or usbmuxd/adb did not answer in time).</summary>
    NoAnswer,

    /// <summary>The phone sent something that is not valid protocol.</summary>
    ProtocolError,

    /// <summary>Any other failure of the link.</summary>
    ConnectionLost,
}
