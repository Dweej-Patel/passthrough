namespace Passthrough.Core.Protocol;

/// <summary>Constants shared with the phone (protocol/README.md).</summary>
public static class ProtocolConstants
{
    public const int Version = 2;
    public const int SocksPort = 7890;
    public const int ControlPort = 7891;
    public static readonly TimeSpan PairingCodeLifetime = TimeSpan.FromSeconds(300);
    public static readonly TimeSpan UnauthenticatedTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan PingInterval = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan SilenceLimit = TimeSpan.FromSeconds(20);
    public const int MaxLineBytes = 262144;
}
