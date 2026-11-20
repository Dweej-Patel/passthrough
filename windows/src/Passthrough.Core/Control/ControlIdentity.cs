namespace Passthrough.Core.Control;

/// <summary>
/// Who this PC is on the control channel. <paramref name="Token"/> is the pairing token the proofs are made
/// with; it is never sent. Null: this PC holds no pairing for the phone, which then counts as unpaired.
/// </summary>
public sealed record ControlIdentity(string ClientId, string Name, string? Token);
