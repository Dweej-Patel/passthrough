namespace Passthrough.Core.Shell;

/// <summary>Reasons a host gives in an <c>error</c> line; port of <c>ShellError</c> in ShellProtocol.swift.</summary>
public enum ShellError
{
    NotAuthorized,
    TooManySessions,
    NoSuchSession,
    BadRequest,
    /// <summary>The phone has shell access but not screen access.</summary>
    ScreenNotAllowed,
    /// <summary>Screen Sharing is off (nothing answers on its port).</summary>
    ScreenUnavailable,
    /// <summary>The host can't stream its screen itself.</summary>
    ScreenVideoUnavailable,
    /// <summary>The host already shows its screen to as many views as it allows.</summary>
    TooManyScreens,
    /// <summary>The owner hasn't let this phone change Keep awake and the VPN.</summary>
    NotAllowed,
    /// <summary>The VPN can't turn on: no VPN is set up.</summary>
    VpnNotSetUp,
    /// <summary>A screen-only pass asked for something other than the screen.</summary>
    ScreenOnly,
    /// <summary>The host couldn't save a pass.</summary>
    PassNotSaved,
    /// <summary>No shell can start: the granting account isn't signed in, or Passthrough isn't open there.</summary>
    SignedOut,
    /// <summary>The Remote Desktop relay can't be used now (<c>detail</c> says why).</summary>
    RdpUnavailable,
    /// <summary>Too many tries in a short time (<c>retryAfter</c>).</summary>
    TryLater,
    /// <summary>The host already lets in as many computers as it allows (8 a phone, 16 in all).</summary>
    TooManyComputers,
    /// <summary>A hand-over would replace access to a host with different details (its certificate or iroh id).</summary>
    PassConflict,
}
