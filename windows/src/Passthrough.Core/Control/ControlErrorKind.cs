namespace Passthrough.Core.Control;

/// <summary>Why the PC closed a control channel itself.</summary>
public enum ControlErrorKind
{
    /// <summary>The phone said it was paired but could not prove it.</summary>
    ProofFailed,

    /// <summary>The phone speaks another protocol version.</summary>
    Incompatible,
}
