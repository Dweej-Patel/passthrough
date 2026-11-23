namespace Passthrough.Core.Cable;

/// <summary>
/// Who is at the far end of a control channel's connection, as the cable peer check found it before anything was
/// proved: Apple's own device service for an iPhone or iPad, an adb server running as this user in this session for
/// an Android phone (stage 3, "The cable peer check"). Only <see cref="Genuine"/> lets a shell grant go out; the
/// phone pairs and shows its status either way.
/// </summary>
public enum PeerVerdict
{
    /// <summary>Not checked, or the check could not decide: no grant.</summary>
    Unknown,
    /// <summary>The far end is the system's own service for this kind of phone.</summary>
    Genuine,
    /// <summary>Something else holds the far end (another account's program, a stand-in): no grant.</summary>
    NotGenuine,
}
