namespace Passthrough.Core.Transport;

/// <summary>A phone arriving in, or leaving, the <see cref="DeviceDirectory"/>.</summary>
public abstract record DeviceChange
{
    private DeviceChange() { }

    public sealed record Attached(PhoneDevice Device) : DeviceChange;

    public sealed record Detached(PhoneDevice Device) : DeviceChange;
}
