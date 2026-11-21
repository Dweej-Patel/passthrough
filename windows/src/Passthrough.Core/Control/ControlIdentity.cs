namespace Passthrough.Core.Control;

/// <summary>
/// Who this PC is on the control channel. <paramref name="Token"/> is the pairing token the proofs are made
/// with; it is never sent, and never printed (<see cref="ToString"/> leaves it out). Null: this PC holds no
/// pairing for the phone, which then counts as unpaired.
/// </summary>
public sealed record ControlIdentity(string ClientId, string Name, string? Token)
{
    public override string ToString() =>
        $"ControlIdentity {{ ClientId = {ClientId}, Name = {Name}, Token = {(Token is null ? "none" : "(redacted)")} }}";
}
