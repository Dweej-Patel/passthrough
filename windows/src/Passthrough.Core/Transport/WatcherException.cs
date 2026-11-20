namespace Passthrough.Core.Transport;

/// <summary>A failure one watcher absorbed, as <see cref="DeviceDirectory.Error"/> reports it: names the transport, wraps the cause.</summary>
public sealed class WatcherException(WatchTransport transport, Exception inner)
    : Exception($"{transport} watcher: {inner.GetType().Name}: {inner.Message}", inner)
{
    public WatchTransport Transport { get; } = transport;
}
