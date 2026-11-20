namespace Passthrough.Core.Protocol;

/// <summary>Reasons a pairing attempt can fail, sent back over the control channel.</summary>
public enum PairingFailure { BadCode, Expired, NotAuthenticated, UnsupportedVersion, Locked, CodeWithdrawn }

/// <summary>Wire names for <see cref="PairingFailure"/> (C# enums cannot hold static methods).</summary>
public static class PairingFailureWire
{
    /// <summary>Unknown or missing reasons are <see cref="PairingFailure.BadCode"/>.</summary>
    public static PairingFailure Parse(string? reason) => reason switch
    {
        "bad_code" => PairingFailure.BadCode,
        "expired" => PairingFailure.Expired,
        "not_authenticated" => PairingFailure.NotAuthenticated,
        "unsupported_version" => PairingFailure.UnsupportedVersion,
        "locked" => PairingFailure.Locked,
        "code_withdrawn" => PairingFailure.CodeWithdrawn,
        _ => PairingFailure.BadCode,
    };

    public static string ToWire(this PairingFailure failure) => failure switch
    {
        PairingFailure.BadCode => "bad_code",
        PairingFailure.Expired => "expired",
        PairingFailure.NotAuthenticated => "not_authenticated",
        PairingFailure.UnsupportedVersion => "unsupported_version",
        PairingFailure.Locked => "locked",
        PairingFailure.CodeWithdrawn => "code_withdrawn",
        _ => throw new ArgumentOutOfRangeException(nameof(failure)),
    };
}
