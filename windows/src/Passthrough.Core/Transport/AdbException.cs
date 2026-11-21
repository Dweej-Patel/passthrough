namespace Passthrough.Core.Transport;

/// <summary>The adb server answered FAIL; the message is the server's own text.</summary>
public sealed class AdbException(string message) : Exception(message);
