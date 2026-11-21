namespace Passthrough.Core.Protocol;

/// <summary>A control line that is not valid protocol.</summary>
public sealed class ProtocolException(string message) : Exception(message);
