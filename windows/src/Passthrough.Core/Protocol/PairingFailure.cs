namespace Passthrough.Core.Protocol;

/// <summary>Reasons a pairing attempt can fail, sent back over the control channel.</summary>
public enum PairingFailure { BadCode, Expired, NotAuthenticated, UnsupportedVersion, Locked, CodeWithdrawn }
