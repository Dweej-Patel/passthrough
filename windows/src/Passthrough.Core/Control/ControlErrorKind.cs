namespace Passthrough.Core.Control;

/// <summary>Why a control channel ended in a way retrying cannot fix.</summary>
public enum ControlErrorKind
{
    /// <summary>The phone said it was paired but could not prove it.</summary>
    ProofFailed,

    /// <summary>The phone speaks another protocol version.</summary>
    Incompatible,

    /// <summary>The phone did not accept this PC's proof of the pairing (<c>error not_authenticated</c> after <c>auth</c>).</summary>
    NotAuthenticated,
}
