namespace Passthrough.Core.Transport;

public abstract record UsbMuxEvent
{
    private UsbMuxEvent() { }

    public sealed record Attached(UsbMuxDevice Device) : UsbMuxEvent;

    public sealed record Detached(int DeviceId) : UsbMuxEvent;
}
