namespace Passthrough.Core.Transport;

public sealed record UsbMuxDevice(int DeviceId, string Udid, int ProductId, string ConnectionType)
{
    public bool IsUsb => ConnectionType.Equals("USB", StringComparison.OrdinalIgnoreCase);
}
