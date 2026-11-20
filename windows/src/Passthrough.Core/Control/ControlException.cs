namespace Passthrough.Core.Control;

/// <summary>
/// The control channel ended in a way retrying cannot fix: the phone could not prove its pairing, did not accept
/// this PC's proof, or speaks another protocol version (<paramref name="phoneIsOlder"/> says which side to update).
/// The message is shown to the user.
/// </summary>
public sealed class ControlException(ControlErrorKind kind, string deviceKind, bool phoneIsOlder = false)
    : Exception(Describe(kind, deviceKind, phoneIsOlder))
{
    public ControlErrorKind Kind { get; } = kind;

    /// <summary>"iPhone", "iPad" or "Android phone": the device the message names.</summary>
    public string DeviceKind { get; } = deviceKind;

    /// <summary>For <see cref="ControlErrorKind.Incompatible"/>: true when the phone needs updating, false when this PC does.</summary>
    public bool PhoneIsOlder { get; } = phoneIsOlder;

    private static string Describe(ControlErrorKind kind, string deviceKind, bool phoneIsOlder) => kind switch
    {
        ControlErrorKind.ProofFailed =>
            $"The {deviceKind} on the cable could not prove it is paired with this PC. If it is yours, use Forget Pairing in Settings and pair again.",
        ControlErrorKind.NotAuthenticated =>
            $"The {deviceKind} on the cable did not accept this PC's pairing. If it is yours, use Forget Pairing in Settings and pair again.",
        ControlErrorKind.Incompatible when phoneIsOlder =>
            $"Passthrough on the {deviceKind} is out of date. Update it on the {deviceKind}, then connect again.",
        ControlErrorKind.Incompatible =>
            "Passthrough on this PC is out of date. Update it on this PC, then connect again.",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}
